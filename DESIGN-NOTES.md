# DESIGN-NOTES

This document records the main design choices behind the `fibers` library and the intended architectural boundaries for extension and porting.

It is aimed at readers who are already comfortable with concurrent programming.

---

## 1. Overview

`fibers` provides:

- a cooperative scheduler and lightweight fibers;
- an algebra of *operations* (“Ops”) for describing blocking, choice and abort behaviour;
- structured concurrency scopes with fail-fast supervision;
- a small set of primitives (sleep, channels, I/O streams, processes).

Key ideas:

- treat “things that may block or complete in the future” as first-class values (Ops);
- treat lifetimes (scopes, fibers, I/O, child processes) as part of the same coordination model;
- constrain lifetimes to a tree of scopes, so work and resources terminate together.

The same machinery is used for in-memory primitives (channels, timers), I/O, and child processes.

---

## 2. Heritage and influences

The design draws on several existing models:

- **CSP**
  - synchronous channels and rendezvous;
  - emphasis on message passing and composition.

- **Concurrent ML (CML)**
  - first-class events and an algebra for combining them;
  - choice over multiple events with abort behaviour (negative acknowledgements).

- **Structured concurrency** (e.g. Trio, Kotlin coroutines, OCaml Eio)
  - scopes as supervision domains;
  - fail-fast semantics and tree-shaped lifetime.

- **Actor/supervision systems** (e.g. Erlang/OTP)
  - failures organised along a supervision tree;
  - “let it fail” with recovery at boundaries.

The library is not a direct port of any single system. It uses:

- CML-style events as “Ops”;
- a scope tree for lifetime and failure accounting;
- CSP-style channels expressed as Ops;
- I/O and process execution expressed as further Ops.

---

## 3. Core concurrency model

### 3.1 Fibers and scheduler

The scheduler (`fibers.runtime`) manages **fibers**: lightweight, cooperatively scheduled execution contexts.

Fibers:

- are spawned via `fibers.spawn(fn, ...)`, under the current scope;
- yield control only by *performing* Ops (directly or via helpers such as sleep, channels, I/O);
- do not run in parallel within a single scheduler; concurrency is interleaving rather than pre-emptive multithreading.

The scheduler works with task sources (poller, timers, etc.) which re-schedule fibers when external conditions change.

`fibers.runtime` also provides an error pump interface (`wait_fiber_error`) so uncaught fiber errors can be attributed and handled at a higher layer (scopes).

### 3.2 Ops and the event algebra

Ops (`fibers.op`) represent deferred blocking operations. Each Op is a value describing:

- how to check readiness without blocking;
- how to register interest and suspend;
- how to resume the fiber when ready.

Primitive Ops are built with `op.new_primitive(wrap, try, block)`:

- `try()` is a non-blocking probe returning:
  - `true, ...results...` when ready; or
  - `false` when not ready (must block);
- `block(suspension, wrap)` registers the suspension with some external mechanism (timer wheel, poller, waitset, etc.).

On top of primitives, the library provides combinators:

- `op.choice(a, b, ...)` – wait for the first ready leaf;
- `op.named_choice{ name = op, ... }`, `op.boolean_choice(a, b)`;
- `op.guard(f)` – build an Op lazily (at perform time);
- `op.with_nack(f)` and `:on_abort(f)` – abort behaviour for losing arms in a choice;
- `op.bracket(acquire, release, use)` – ensure release runs on both success and abort;
- `op.always(...)` / `op.never()` – immediate and never-ready events;
- helper forms: `race`, `first_ready`.

Ops are passive until performed.

#### Performing Ops

There are two relevant ways to perform Ops in normal code:

- `fibers.perform(op)` (via `fibers.performer.perform`)
  - must be called from inside a fiber;
  - uses the current scope when available (and therefore honours cancellation and fail-fast semantics);
  - otherwise falls back to `op.perform_raw(op)`.

- `op.perform_raw(op)`
  - executes an Op directly in the current fiber without consulting scope state;
  - used by scope internals (notably join/finalisation) and other carefully controlled paths.

Most user-facing code should use `fibers.perform` (or `fibers.try_perform` when status-first handling is required).

### 3.3 Structured concurrency scopes

Scopes (`fibers.scope`) are supervision domains and form a tree.

A scope provides:

- **admission gating**: `close(reason)` stops new work being admitted (spawn/child); join also closes admission;
- **downward cancellation**: `cancel(reason)` closes admission and cancels attached children;
- **fail-fast semantics**: the first non-cancellation error becomes the primary failure, and triggers cancellation of the scope to stop siblings;
- **deterministic join**: join runs in a join worker and uses `op.perform_raw` so it is not interrupted by the scope’s own cancellation;
- **finalisers**: LIFO `scope:finally(fn)` handlers run during join.

Scopes track a status with the observable values:

- `"running"` (pre-join, no failure/cancellation recorded)
- `"failed"` (primary failure recorded)
- `"cancelled"` (cancellation reason recorded)
- `"ok"` (only after join completes successfully)

A scope also carries a `report` snapshot produced at join:

```lua
report = {
  id           = <scope id>,
  extra_errors = { ... },  -- secondary errors after the primary is established
  children     = { ... },  -- child outcomes (each includes nested report)
}
```

#### Current scope attribution

Scope attribution is fiber-local:

* inside a fiber: `Scope.current()` returns the fiber’s scope (defaulting to the process root);
* outside a fiber: `Scope.current()` returns the process root.

There is no separate “global current scope” distinct from root. This keeps attribution rules simple and avoids cross-context leakage.

A weak-key map (fiber → scope) is used to attribute uncaught runtime fiber errors to the owning scope.

#### Failure and cancellation policy

The scope uses a single primary record:

* on failure: the scope records `_failed_primary` and then calls `cancel(_failed_primary)`;
* cancellation reason becomes the value propagated downwards to child scopes;
* subsequent errors, once a primary has been established, are appended to `report.extra_errors` and do not replace the primary.

A cancellation sentinel (`fibers.cancelled`) is used for cancellation-as-control-flow across error channels. Escaping cancellation is treated as cancellation, not failure.

#### Join and finalisation

Join is represented as an Op:

* `Scope:join_op()` becomes ready once join has completed and the scope has reached a terminal state;
* it yields:

```lua
st, report, primary_or_nil
```

Finalisers run during join, after:

1. admission is closed;
2. the scope’s internal waitgroup drains (all spawned fibers complete);
3. attached child scopes join in attachment order.

Finalisers are called as:

```lua
fn(aborted, st, primary_if_failed_or_nil)
```

where:

* `aborted` is `true` when `st ~= "ok"`;
* `st` is `"ok"|"failed"|"cancelled"`;
* the third argument is the primary value only when `st == "failed"`.

If a finaliser raises:

* if the scope would otherwise be ok, the first such error becomes the primary failure;
* if the scope is already failed or cancelled, the error is recorded as a secondary error.

#### Scope-aware operation performance

Scopes integrate with Ops via a “race body vs not-ok” pattern.

* `Scope:try_op(ev)` returns an Op that yields:

```lua
"ok", ...results...
"failed", primary
"cancelled", reason
```

* `Scope:try(ev)` performs `try_op(ev)` (must be called inside a fiber).
* `Scope:perform(ev)` returns results on ok; on failure it raises the primary; on cancellation it raises a cancellation sentinel.

The core rule is: successful results are only returned when the scope remains ok; if the scope has failed or been cancelled, the operation is treated as not-ok.

### 3.4 Scope boundaries as values

Scope boundaries are exposed in two forms:

* `Scope.run(body_fn, ...)`

  * runs `body_fn(child_scope, ...)` in a fresh child scope;
  * waits until that scope joins;
  * returns status-first:

```lua
st, report, ...         -- on ok: ... are results
st, report, primary     -- on not-ok
```

* `Scope.run_op(body_fn, ...)`

  * returns an Op that performs the same boundary;
  * suitable for use in `choice`/`race` (timeouts, cancellation triggers, etc.);
  * on abort (losing a choice), the child scope is cancelled with reason `"aborted"` and then joined deterministically.

A notable design choice is that the boundary Op is intentionally not “fast-path eager”: its primitive `try` path does not attempt completion without blocking. This simplifies correctness and avoids subtle partial-state completion races; the boundary is driven by the child join.

### 3.5 Waitsets and `waitable`

`fibers.wait` provides infrastructure for building blocking primitives.

#### Waitset

`Waitset` is a keyed set of scheduler tasks:

* `add(key, task)` returns a token with `token:unlink()`;
* `take_one(key)` / `take_all(key)` remove and return waiters;
* `notify_one(key, sched)` / `notify_all(key, sched)` schedule waiting tasks;
* `clear_key`, `clear_all`, `is_empty`, `size`.

It is used by poller backends (read/write readiness keyed by fd), and by process backends (waiters keyed by pid or pidfd).

#### `waitable(register, step, wrap)`

`waitable` builds an Op from:

* a non-blocking `step()` returning:

  * `true, ...` when ready; or
  * `false` when not ready;
* a `register(task, suspension, leaf_wrap)` that arranges for `task:run()` to be called when progress may have occurred.

It ensures that:

* the operation participates correctly in `choice` and abort behaviour;
* outstanding registrations are cancelled on abort via `token:unlink()`.

This pattern is used for timers, poller readiness, stream I/O, socket accept/connect, and process completion.

---

## 4. I/O architecture

The I/O stack is layered to separate platform-neutral abstractions from platform-specific backends.

### 4.1 Streams and `StreamBackend`

`fibers.io.stream` defines a buffered `Stream` over an abstract `StreamBackend`.

A `StreamBackend` is expected to provide:

* `read_string(max)` -> `data|nil, err|nil`;
* `write_string(data)` -> `bytes_written|nil, err|nil`;
* `on_readable(task)` / `on_writable(task)` -> `WaitToken`;
* `close()`, and optionally `seek`, `nonblock`, `block`, `fileno`, `filename`.

`Stream` exposes:

* core Ops: `read_string_op`, `write_string_op`, etc.;
* derived Ops: `read_line_op`, `read_exactly_op`, `read_all_op`;
* Lua-compatible `read_op`/`write_op` forms;
* synchronous wrappers calling `fibers.perform`, therefore respecting scope semantics.

### 4.2 Poller and readiness

A poller is a task source that converts kernel readiness into scheduled tasks, typically through keyed waitsets.

Backends (epoll, poll/select) are intended to be interchangeable behind a stable interface.

### 4.3 Files and sockets

`fibers.io.file` and `fibers.io.socket` are thin layers over:

* an fd backend (`fibers.io.fd_backend`) that performs system calls and integrates with the poller;
* `Stream` as the user-facing buffered interface.

Socket accept/connect are expressed as Ops using `waitable`, so they can be composed in `choice` and respect scope cancellation.

---

## 5. Error handling, cancellation and lifetimes

### 5.1 Fail-fast supervision

Error handling is organised around scopes:

* an uncaught error in any fiber is attributed to that fiber’s current scope;
* the first such error becomes the scope’s primary failure and triggers cancellation of the scope;
* cancellation is propagated down the tree to attached children.

This supports “let it fail” within a scope, and boundary-based reporting.

### 5.2 Cancellation as an event

Cancellation is integrated into the event algebra:

* a scope provides `fault_op`, `cancel_op`, and `not_ok_op`;
* `Scope:try_op(ev)` races the body against scope not-ok and re-checks after completion;
* `fibers.perform` therefore returns results only when the scope remains ok.

The same approach is used in higher-level facilities, such as timeouts (race an operation against `sleep.sleep_op`) and aborting entire subtrees (abort behaviour on `run_op`).

### 5.3 Finalisers and resource cleanup

Scopes provide LIFO finalisers via `scope:finally(fn)`:

* run exactly once during join (after child fibers drain, and after joining attached children);
* are passed enough information to distinguish normal exit from failure/cancellation;
* errors in finalisers are captured and recorded as primary or secondary errors according to whether the scope was otherwise ok.

This is the primary mechanism for tying external resources to a unit of work.

---

## 6. Relationship to other models

### 6.1 Futures and async/await

In many future-based models:

* a future is the primary unit of concurrency and cancellation;
* structured concurrency is layered on.

In this library:

* the primary representation of “waiting” is the Op;
* cancellation is primarily a scope property, not an operation-local property;
* lifetimes are grouped into a scope tree, with boundaries as explicit results.

### 6.2 Go-style goroutines and channels

The combination of fibers and channels is similar in spirit to Go. The main differences are:

* selection is expressed via the event algebra (`choice`, `named_choice`) rather than a language `select`;
* scopes enforce lifetime and cancellation boundaries for groups of fibers;
* blocking operations are explicit values (Ops) which can be composed without helper fibers.

### 6.3 Actor/supervision systems

The scope tree resembles a supervision tree:

* failures are attributed to a domain and prompt coordinated shutdown;
* cleanup is deterministic via join and finalisers.

The model remains cooperative and single-scheduler, with channels/streams rather than actor mailboxes as the primary communication tools.

---

## 7. Intended usage patterns

### 7.1 Application entry point

From non-fiber code:

* call `fibers.run(main_fn, ...)`.

Inside `main_fn(scope, ...)`:

* use `fibers.spawn(fn, ...)` to create child fibers under the current scope;
* use `fibers.run_scope(fn, ...)` to create nested supervision domains and observe outcomes;
* use `fibers.run_scope_op(fn, ...)` when you need a scope boundary to participate in `choice`/`race`;
* perform Ops via `fibers.perform(ev)` (or `fibers.try_perform(ev)` when status-first handling is required).

### 7.2 I/O services

Use the top-level modules:

* `fibers.io.file` for file streams and pipes;
* `fibers.io.socket` for UNIX sockets;
* `fibers.channel` for in-memory communication;
* `fibers.sleep` for timers.

Avoid depending directly on platform-specific backends in application code. This keeps portability concerns confined to backend modules.

### 7.3 Coordination and cancellation

Express coordination using the event algebra and scope boundaries:

* race I/O against timeouts with `named_choice`;
* coordinate multiple producers/consumers through channels;
* bind requests/sessions/jobs to their own scope and cancel that scope to stop all related work and cleanup.

---

## 8. Extension points and future work

The architecture is intended to be open to new backends and platforms.

### 8.1 Poller backends

To integrate a new kernel event mechanism:

* implement a backend module providing:

  * `new_backend()`;
  * `poll(state, timeout_ms, rd_waitset, wr_waitset)`;
  * optional `on_wait_change`, `close_backend`, `is_supported`;
* add it to the candidate list in the poller selection module.

### 8.2 FD and stream backends

To support new handle types or platforms:

* implement an fd backend providing:

  * non-blocking mode control;
  * read/write primitives;
  * readiness registration integrated with the poller;
  * file helpers (open, pipe, tmpfile support) and, where relevant, socket helpers.

Streams (`fibers.io.stream`) should not need modification.

### 8.3 Exec backends

To add process management on other platforms:

* implement an exec backend providing:

  * spawn/start;
  * non-blocking status polling;
  * readiness registration as an Op via `waitable` patterns;
  * termination/kill, and backend cleanup.

The higher-level `fibers.exec` layer should remain stable.

### 8.4 Cross-platform targets

While current implementations target Unix-like platforms, the layering is designed so that:

* the public APIs for I/O and exec are independent of any particular syscall interface;
* backends encapsulate dependencies on epoll/select, signals, fork/exec, pidfd, and so on.

The intention is that new platform support is primarily a backend exercise, not a model redesign.

---

## 9. Summary

The main design choices are:

* adopt a CML-style event algebra (Ops) as the common representation for all blocking behaviour;
* treat scope lifetime boundaries as values (direct returns or Ops) so they compose with the same algebra;
* organise concurrent work into a tree of scopes with fail-fast supervision and structured cancellation;
* express channels, timers, I/O and processes uniformly in terms of Ops and scopes;
* keep top-level I/O and exec modules free of direct system call dependencies, delegating those concerns to pluggable backends;
* make `fibers.perform` scope-aware so application code consistently observes structured cancellation when run inside fibers.

The result is a small, coherent foundation for building concurrent systems with explicit lifetime boundaries and predictable cleanup.
