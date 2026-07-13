# DESIGN-NOTES

This document captures the design choices behind `fibers`, and where the seams are for extension and porting. It assumes you already know the usual concurrent-programming vocabulary, and wants to tell you what *this* library is trying to be (and what it is trying hard *not* to be).

The short version: **Ops describe waiting**, **scopes describe lifetime**, and everything else lines up behind those two ideas.

---

## 1. Overview

`fibers` provides:

* a cooperative scheduler and lightweight fibers;
* an algebra of *operations* (“Ops”) for blocking, choice, abort, and cleanup;
* structured concurrency scopes with fail-fast supervision;
* a small “standard kit”: sleep, channels, streams, sockets, processes.

The key design choices:

* **Waiting is a value**: “this might complete later” is represented as an `Op`, not as “call this and hope it doesn’t block”.
* **Lifetime is a tree**: scopes form a tree; work and resources live and die within that tree.
* **One model for everything**: in-memory primitives, kernel I/O readiness, and subprocess completion all show up as Ops, and are governed by scopes.

If you can race a channel receive against a timeout, you can do the same with `accept()`, `read_line()`, `waitpid()`, or “join this entire subtree”.

---

## 2. Heritage and influences

This is a hybrid of several well-known ideas:

* **CSP**: rendezvous channels; composition through message passing.
* **Concurrent ML (CML)**: first-class events; choice; “losing arms” get abort signals (negative acknowledgements).
* **Structured concurrency** (Trio, Kotlin coroutines, Eio): scopes as supervision domains; tree-shaped lifetime; cancellation as a normal termination mode.
* **Actor/supervision systems** (Erlang/OTP): organise failure; “let it fail” locally, recover at boundaries.

`fibers` is not a direct port. It borrows the *shapes*:

* CML-style events become **Ops**.
* a supervision tree becomes a **scope tree**.
* CSP-style channels are expressed as **Ops**.
* I/O and processes become **more Ops**.

---

## 3. Core concurrency model

### 3.1 Fibers and the scheduler

The runtime (`fibers.runtime`) manages **fibers**: cooperatively scheduled coroutines.

* `fibers.spawn(fn, ...)` creates a fiber under the current scope.
* A fiber yields only when it performs an op (directly or via helpers like sleep, channels, I/O).
* There is no parallel execution inside one scheduler; concurrency is interleaving, not pre-emptive multithreading.

The scheduler also hosts **task sources** (poller, timers, etc.) which can re-schedule fibers when an external condition changes.

Finally, the runtime exposes an error pump (`wait_fiber_error`) so uncaught fiber failures can be attributed and handled above the runtime layer (by scopes).

### 3.2 Ops: the event algebra

Ops (`fibers.op`) represent deferred blocking operations. A primitive op is defined by:

* how to check readiness without blocking (`try`);
* how to arrange suspension and future wake-up (`block`);
* and a commit-phase wrapper (`wrap`) that is only applied on completion.

Primitive ops are constructed with:

```lua
op.new_primitive(wrap, try, block)
```

* `try()` is a non-blocking probe:

  * returns `true, ...results...` if ready;
  * returns `false` if not ready.
* `block(suspension, wrap)` registers interest (timer wheel, poller, waitset, etc.) and must arrange eventual completion.

Everything else is composition:

* `op.choice(...)` / `named_choice` / `boolean_choice` / `race`
* `op.guard(f)` (lazy construction at perform-time)
* `op.with_nack(f)` and `:on_abort(f)` (losing-arm behaviour)
* `op.bracket(acquire, release, use)` / `:finally(cleanup)`
* `op.always(...)` / `op.never()`

Ops are **passive** until performed.

#### Performing Ops

There are two execution modes, and they exist for a reason:

* `fibers.perform(ev)`

  * must be called from inside a fiber;
  * performs under the current scope (so cancellation and fail-fast semantics are honoured).

* `op.perform_raw(ev)`

  * performs without consulting scope state;
  * used in carefully controlled internal paths (notably join/finalisation) where you must not be interrupted by cancellation.

User code should almost always use `fibers.perform`. There is intentionally no top-level `try_perform`: the intended style is “throw freely; handle at boundaries; clean up with `finally`”.

### 3.3 Structured concurrency scopes

Scopes (`fibers.scope`) are supervision domains arranged as a tree.

A scope provides:

* **admission gating**: `close(reason)` stops new work (spawn/child); join also closes admission;
* **downward cancellation**: `cancel(reason)` closes admission and cancels attached children;
* **fail-fast semantics**: the first non-cancellation error becomes the primary failure and triggers cancellation to stop siblings;
* **deterministic join**: join runs in a join worker and uses `op.perform_raw` so finalisation is not interrupted by scope cancellation;
* **finalisers**: `scope:finally(fn)` runs during join in LIFO order.

Observable status (informally):

* `"running"`: active, not yet terminal
* `"failed"`: primary failure recorded
* `"cancelled"`: cancellation recorded
* terminal outcome materialises at join (`"ok"|"failed"|"cancelled"`)

A join report has the shape:

```lua
report = {
  id           = <scope id>,
  extra_errors = { ... },
  children     = { ... },
}
```

#### Current scope attribution

Attribution is fiber-local:

* inside a fiber: `Scope.current()` is that fiber’s scope (defaulting to root);
* outside fibers: `Scope.current()` is root.

Uncaught runtime fiber errors are attributed using a weak-key map `fiber -> scope`, so scope accounting stays accurate without creating memory leaks.

#### Failure and cancellation policy

Scopes keep one “primary” record:

* on failure: record `_failed_primary`, then cancel the scope with that value (single source of truth);
* the cancellation reason propagates down to children;
* subsequent errors are appended to `extra_errors` and do not replace the primary.

Cancellation is represented internally using a robust sentinel (`fibers.cancelled`) so it can travel through Lua’s error channel without colliding with ordinary errors. Escaping cancellation is treated as cancellation, not failure.

#### Join and finalisation

Join is represented as an op:

* `Scope:join_op()` becomes ready once the join worker finishes;
* it yields `st, report, primary_or_nil`.

Finalisation order:

1. admission closes;
2. the scope’s internal waitgroup drains (spawned fibers complete);
3. attached child scopes join in attachment order;
4. finalisers run in LIFO order.

Finalisers are called as:

```lua
fn(aborted, st, primary_if_failed_or_nil)
```

If a finaliser raises:

* if the scope would otherwise be ok, the first finaliser error becomes the primary failure;
* if the scope is already failed/cancelled, it becomes a secondary error.

#### Scope-aware op performance

Scopes integrate with ops by racing “the body” against “scope not-ok”, and re-checking after completion:

* `Scope:try_op(ev)` yields one of:

```lua
"ok", ...results...
"failed", primary
"cancelled", reason
```

* `Scope:perform(ev)` returns results on ok; raises on failed/cancelled.

The rule is deliberately strict: **results are only returned if the scope remains ok**. If the scope has already failed or been cancelled, performing is treated as not-ok.

### 3.4 Scope boundaries as values

Boundaries are exposed in two forms:

* `Scope.run(body_fn, ...)` returns status-first:

```lua
st, report, ...         -- on ok
st, report, primary     -- on not-ok
```

* `Scope.run_op(body_fn, ...)` returns an op that resolves when the child scope has joined.

On abort (losing a choice), the boundary op cancels the child scope with reason `"aborted"` and then joins it deterministically.

A design note that matters in practice: the boundary op is not “eager”. Its readiness is driven by the child join, rather than trying to opportunistically fast-path completion. This keeps correctness simple and avoids partial-state races.

### 3.5 Waitsets and `waitable`

`fibers.wait` is the glue for building “real” blocking primitives in a disciplined way.

#### Waitset

`Waitset` is a keyed set of scheduler tasks (fd, pid, object key, anything):

* `add(key, task)` returns a token with `token:unlink()`;
* `take_one` / `take_all`;
* `notify_one` / `notify_all`;
* `clear_key`, `clear_all`, `is_empty`, `size`.

Pollers typically key by fd and direction; process backends key by pid or pidfd.

#### `waitable(register, step, wrap)`

`waitable` builds an op from:

* a non-blocking `step()`:

  * returns `true, ...` when ready;
  * returns `false` when not ready;
* a `register(task, suspension, leaf_wrap)` which arranges for `task:run()` to be called when progress may have occurred.

Crucially:

* registrations are cancelled on abort via `token:unlink()`.

This is the mechanism that makes “race read against timeout” safe: losing arms do not keep dangling fd interest in the poller. In practice, this pattern underpins stream I/O, socket accept/connect, and process completion.

---

## 4. I/O architecture

The I/O stack is intentionally layered so that portability work is concentrated in backends.

### 4.1 Streams and `StreamBackend`

`fibers.io.stream` defines a buffered `Stream` over a `StreamBackend`.

A backend provides:

* `read_string(max)` / `write_string(data)`
* `on_readable(task)` / `on_writable(task)` → `WaitToken`
* `close()`
* optionally `seek`, `nonblock`, `block`, `fileno`, `filename`

`Stream` then exposes ops:

* core: `read_string_op`, `write_string_op`
* derived: `read_line_op`, `read_exactly_op`, `read_all_op`
* Lua-compat: `read_op` / `write_op`

Synchronous wrappers call `fibers.perform`, so scope cancellation and fail-fast behaviour apply automatically.

### 4.2 Poller and readiness

A poller is a scheduler task source that translates kernel readiness into scheduled tasks, typically by:

* keeping waitsets for read and write readiness,
* polling with a timeout,
* notifying and scheduling tasks for ready keys.

Backends (epoll, poll/select, etc.) are intended to be interchangeable behind a stable interface.

### 4.3 Files and sockets

`fibers.io.file` and `fibers.io.socket` are thin layers over:

* an fd backend (`fibers.io.fd_backend`) that does syscalls and integrates with the poller;
* `Stream` as the user-facing interface.

Socket accept/connect are expressed as ops (typically via `waitable`), so they compose with `choice` and respect scope cancellation.

---

## 5. Error handling, cancellation, and lifetimes

### 5.1 Fail-fast supervision

Errors are organised around scopes:

* uncaught errors in fibers are attributed to the fiber’s scope;
* the first becomes the scope’s primary failure and triggers cancellation;
* cancellation propagates down to attached child scopes.

This supports “let it fail” locally and reporting at boundaries.

### 5.2 Cancellation as an event

Cancellation is not bolted on as a separate signalling system; it participates in the same model:

* scopes provide `fault_op`, `cancel_op`, `not_ok_op`;
* `Scope:try_op(ev)` races the body against scope not-ok and re-checks after completion;
* `fibers.perform` therefore only returns results when the scope remains ok.

Timeouts and aborting subtrees are then just ordinary compositions:

* timeout = `choice(op, sleep_op(dt))`
* abort subtree = `run_scope_op(...)` losing in an outer choice

### 5.3 Finalisers and cleanup

Finalisers are the main mechanism for tying external resources to a unit of work:

* run exactly once during join;
* receive enough context to distinguish ok/failed/cancelled;
* errors are recorded as primary/secondary depending on whether the scope was otherwise ok.

This is a deliberate push away from “try to catch everything and limp on”. Instead: register cleanup, throw, and let the boundary report.

---

## 6. Relationship to other models

### 6.1 Futures and async/await

In many future-based systems:

* futures are the primary unit of concurrency/cancellation;
* structured concurrency is layered on top.

In `fibers`:

* the primary representation of waiting is the op;
* cancellation is primarily a scope property;
* boundaries are explicit values (direct returns or ops) that compose with the same algebra.

### 6.2 Go-style goroutines and channels

There are familiar similarities (fibers + channels), but:

* selection is expressed via the op algebra (`choice`, `named_choice`), not a language `select`;
* scopes enforce lifetime and cancellation boundaries for groups of fibers;
* blocking operations are explicit values, so you can compose without “helper goroutines”.

### 6.3 Actor/supervision systems

The scope tree resembles a supervision tree:

* failures are attributed to a domain and prompt coordinated shutdown;
* cleanup is deterministic via join and finalisers.

The execution model remains single-scheduler and cooperative; channels/streams are the primary coordination tools rather than actor mailboxes.

---

## 7. Intended usage patterns

### 7.1 Entry point

From non-fiber code:

* call `fibers.run(main_fn, ...)`.

Inside `main_fn(scope, ...)`:

* use `fibers.spawn(fn, ...)` for concurrent work under the current scope;
* use `fibers.run_scope(fn, ...)` when you want a boundary with structured outcomes;
* use `fibers.run_scope_op(fn, ...)` when a boundary must participate in `choice`/`race`;
* perform ops via `fibers.perform(ev)`.

The default posture is “throw, don’t catch”; boundaries are where you observe outcomes.

### 7.2 I/O services

Use the public modules:

* `fibers.io.file` (streams, pipes, tmpfiles)
* `fibers.io.socket` (UNIX sockets)
* `fibers.io.stream` (buffered stream ops)
* `fibers.channel` (in-memory coordination)
* `fibers.sleep` (timers)

Avoid depending on platform-specific backends in application code. Portability lives in backend modules.

### 7.3 Coordination and cancellation

Express coordination using ops and scope boundaries:

* race I/O against timeouts with `named_choice` or `boolean_choice`;
* coordinate producers/consumers via channels;
* bind requests/sessions/jobs to their own scope; cancel that scope to stop and clean up *everything* related to the job.

---

## 8. Extension points and porting seams

The library is built so that “porting” is mostly a backend exercise, not a redesign.

### 8.1 Poller backends

To add a new kernel event mechanism:

* implement:

  * `new_backend()`
  * `poll(state, timeout_ms, rd_waitset, wr_waitset)`
  * optional `on_wait_change`, `close_backend`, `is_supported`

* add it to the poller candidate list.

### 8.2 FD and stream backends

To support new handle types or platforms:

* implement an fd backend providing:

  * non-blocking control
  * read/write primitives
  * readiness registration via the poller
  * file helpers (open, pipe, tmpfile) and socket helpers where relevant

Streams should not need modification.

### 8.3 Exec backends

To add process management support:

* implement:

  * process start/spawn
  * non-blocking status checks
  * readiness registration (often via `waitable` + waitsets)
  * termination/kill and backend cleanup

The high-level `fibers.io.exec` layer is intended to remain stable.

### 8.4 Cross-platform targets

Current implementations focus on Unix-like platforms, but the layering is designed so that:

* public I/O and exec APIs do not encode a syscall model;
* backends encapsulate epoll/select, signals, fork/exec, pidfd, etc.

---

## 9. Summary

The main design choices are:

* adopt a CML-style event algebra (Ops) as the common representation of blocking;
* treat scope boundaries as values (direct returns or ops) so they compose with the same algebra;
* organise concurrent work into a scope tree with fail-fast supervision and structured cancellation;
* express channels, timers, I/O, and processes uniformly in terms of Ops and scopes;
* keep syscalls and platform specifics inside pluggable backends;
* make `fibers.perform` scope-aware so application code consistently observes cancellation and failure.

The result is a small, coherent foundation for building concurrent systems where lifetime is explicit, waiting is composable, and cleanup is predictable-even when things go wrong.
