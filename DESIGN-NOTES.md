# DESIGN-NOTES

This document records the main design choices behind the `fibers` library and the intended architectural boundaries for extension and porting.

It is aimed at readers who are already comfortable with concurrent programming.

---

## 1. Overview

`fibers` provides:

- a cooperative scheduler and lightweight fibers;
- an algebra of *operations* (“Ops”) for describing blocking, choice and cancellation;
- structured concurrency scopes with fail-fast supervision;
- a small set of high-level primitives (sleep, channels, I/O streams, processes).

Key ideas:

- treat “things that may block or complete in the future” as first-class values (Ops);
- treat lifetimes (of scopes, fibers, I/O, child processes) as events within the same algebra;
- use structured concurrency to constrain lifetimes to a tree of scopes, so work and resources terminate together.

The same machinery is used for in-memory primitives (channels, timers), I/O, and child processes.

---

## 2. Heritage and influences

The design draws on several existing models:

- **CSP**:
  - synchronous channels and rendezvous;
  - emphasis on message-passing and composition.

- **Concurrent ML (CML)**:
  - first-class events and an algebra for combining them;
  - choice over multiple events with cancellation via negative acknowledgements.

- **Structured concurrency** (e.g. Trio, Kotlin coroutines, OCaml Eio):
  - scopes as supervision domains;
  - fail-fast semantics and tree-shaped lifetime.

- **Actor/supervision systems** (e.g. Erlang/OTP):
  - failures organised along a supervision tree;
  - emphasis on “let it fail” and restarts at boundaries.

The library is not a direct port of any single system. It uses:

- CML-style events as “Ops”;
- a Trio/Eio-like scope tree for lifetime and failure;
- CSP-style channels built as Ops;
- I/O and process execution expressed as further events.

---

## 3. Core concurrency model

### 3.1 Fibers and scheduler

The scheduler (`fibers.runtime`) manages **fibers**: lightweight, cooperatively scheduled execution contexts.

Fibers:

- are spawned via `fibers.spawn(fn, ...)`, under the current scope;
- yield control only by *performing* Ops (directly or via helpers such as `sleep`, channels, I/O);
- do not run in parallel with each other within a single scheduler; concurrency is interleaving rather than pre-emptive multithreading.

The scheduler works with *task sources* (such as the poller and timers) which reschedule fibers when external events occur.

### 3.2 Ops and the event algebra

Ops (`fibers.op`) represent deferred blocking operations. Each Op is a value describing:

- what condition to wait on;
- how to register for that condition;
- how to resume the fiber when the condition is met.

Primitive Ops are built with `op.new_primitive(wrap, try, block)`:

- `try()` is a non-blocking check that returns either:
  - a ready result; or
  - “not ready, must block”;
- `block(suspension, wrap)` registers the suspension with some external mechanism (timer, poller, waitset, etc.).

On top of this, the library provides an algebra of combinators:

- `op.choice(a, b, ...)` – wait for the first ready event;
- `op.named_choice{ name = op, ... }`, `op.boolean_choice(...)`;
- `op.guard(f)` – lazy construction of an Op (for capturing scope at perform time and similar);
- `op.with_nack(f)` – support for negative acknowledgements in races;
- `op.bracket(acquire, release, use)` – ensure release is called once per acquisition;
- `op.always(...)` – immediately-ready event;
- `op.never()` – never-ready event;
- higher-level helpers: `race`, `first_ready`, `named_choice`, `boolean_choice`.

Ops are passive until performed.

#### Performing Ops

There are three relevant ways to perform Ops:

- `fibers.perform(ev)` – the primary synchronous entry point:
  - implemented by `fibers.performer.perform`;
  - when running inside a fiber, it uses the **current scope** and therefore honours structured cancellation and fail-fast semantics;
  - when called outside a fiber, it falls back to a suitable default (such as a raw perform or a temporary scope).

- `Scope:perform(ev)` / `Scope:sync(ev)`:
  - `sync` returns `(ok, ...)` where `ok` is `false` if the scope is no longer running;
  - `perform` raises on failure or cancellation.

- `op.perform_raw(ev)`:
  - low-level mechanism that directly executes the Op without consulting scopes;
  - used by scheduler and scope internals, and in carefully controlled places where scope semantics would be inappropriate (for example, to finish shutdown after the owning scope has already reached a terminal state).

Normal user-facing code is expected to use `fibers.perform` or `Scope:perform` rather than `op.perform_raw`.

### 3.3 Structured concurrency scopes

Scopes (`fibers.scope`) represent supervision domains and form a tree:

- each fiber runs in a *current* scope;
- each scope has:
  - a parent (except the root);
  - a weak set of child scopes;
  - a waitgroup tracking child fibers;
  - a LIFO stack of `finally` handlers to run on exit;
  - a cancellation condition and a join condition;
  - a status: `"running" | "ok" | "failed" | "cancelled"`;
  - a primary error or cancellation reason, plus a list of additional failures from finalisation handlers.

Scopes are obtained via:

- `Scope.root()` – process-wide root scope (created lazily);
- `Scope.current()` – current scope (per fiber or process-wide “global if not in a fiber”);
- `Scope.run(body_fn, ...)` – create a child scope and run `body_fn(child_scope, ...)` in its own fiber;
- `Scope.with_op(build_op)` – treat “run a child scope whose body is an Op” as an Op itself.

The top-level entry point `fibers.run(main_fn, ...)`:

- must be called outside any fiber;
- initialises the root scope and scheduler;
- runs `main_fn(scope, ...)` inside a child scope and stops the scheduler when that scope completes;
- returns `main_fn`’s results on `"ok"`, or re-raises the primary error/cancellation reason otherwise.

#### Fail-fast behaviour and cancellation

Scopes implement fail-fast supervision:

- if any fiber in a scope raises an uncaught error:
  - the scope status becomes `"failed"` (if it was `"running"`);
  - the primary error is recorded;
  - further uncaught errors from sibling fibers are treated as cancellation noise rather than changing the primary error;
  - cancellation is propagated to all child scopes.

Cancellation is observable as an event:

- `Scope:not_ok_op()` – an Op that becomes ready when the scope is cancelled or fails (but not on success), returning the error or cancellation reason;
- `Scope:join_op()` – an Op that becomes ready once the scope reaches a *terminal* status (after all child fibers and `finally` handlers have completed), returning `(status, err)`.

When a scope exits:

1. a join worker waits for the internal waitgroup (all child fibers finished);
2. if still `"running"`, status is updated to `"ok"`;
3. registered `finally` handlers are run in LIFO order;
4. any errors in `finally` handlers either:
   - if the scope would otherwise have been `"ok"`, turn it into `"failed"` and record the first finaliser error as the primary error; subsequent finaliser errors (if any) are recorded separately; or
   - if the scope is already `"failed"` or `"cancelled"`, are recorded in the scope’s list of additional finaliser failures without changing the primary error;
5. the join condition is signalled, making `join_op` ready.

#### Ops under scopes

Scopes integrate Ops with cancellation:

- `Scope:run_op(ev)` wraps an Op so that scope cancellation is an alternative completion path, using `op.choice(ev, cancel_op(self))`;
- `Scope:sync(ev)`:
  - refuses to run the Op if the scope is not `"running"`;
  - performs the wrapped Op (using `op.perform_raw` internally);
  - checks the scope status again and returns `false, err` if it has since failed or been cancelled;
  - otherwise returns `true, ...results...`.

- `Scope:perform(ev)`:
  - uses `sync`;
  - raises on failure or cancellation.

This arrangement ensures that:

- scoped operations notice scope failure or cancellation promptly;
- results are only treated as successful when the scope has not failed in the meantime.

### 3.4 Waitsets and `waitable`

`fibers.wait` provides infrastructure for building blocking primitives.

#### Waitset

`Waitset` is a keyed set of scheduler tasks:

- `add(key, task)` returns a token with `token:unlink()`;
- `take_one(key)` / `take_all(key)` remove and return waiters;
- `notify_one(key, sched)` / `notify_all(key, sched)` schedule waiting tasks;
- `clear_key`, `clear_all`, `is_empty`, `size`.

It is used by:

- poller backends (`rd`/`wr` waiters keyed by fd);
- the SIGCHLD backend (waiters keyed by PID).

#### `waitable(register, step, wrap)`

`waitable` builds an Op from:

- a non-blocking `step()`:
  - returns `(true, ...)` when ready;
  - returns `(false)` when not ready yet;
- a `register(task, suspension, leaf_wrap)`:
  - records the task;
  - arranges for `task:run()` to be invoked when the external condition may have changed.

It ensures that:

- the operation participates correctly in `choice` and `with_nack`;
- registrations are cancelled when the Op loses a choice;
- repeated wake-ups re-use the same `step` and task.

This pattern is used for:

- channels;
- I/O streams;
- poller and exec backends;
- other primitives that need to integrate with the scheduler.

---

## 4. I/O architecture

The I/O stack is layered to separate platform-neutral abstractions from platform-specific backends.

### 4.1 Streams and `StreamBackend`

`fibers.io.stream` defines a buffered `Stream` over an abstract `StreamBackend`.

A `StreamBackend` is expected to provide:

- `read_string(max)` -> `data|nil, err|nil` (non-blocking, may indicate “would block”);
- `write_string(data)` -> `bytes_written|nil, err|nil`;
- `on_readable(task)` / `on_writable(task)` -> `WaitToken`:
  - integrate with the scheduler (usually via the poller);
- `close()`, `seek(whence, offset)`;
- optional `nonblock`, `block`, `fileno`, `filename`.

`Stream` provides:

- internal ring and linear buffers;
- low-level Ops:
  - `read_into_op(buf, opts)`;
  - `read_string_op(opts)`;
  - `write_string_op(str)`;
  - `flush_output_op()` (currently a no-op for unbuffered output);
- derived Ops:
  - `read_line_op(opts)` – line-oriented reading;
  - `read_exactly_op(n)` – exact byte count or error;
  - `read_all_op()` – read until EOF or error;
- Lua-compatibility Ops:
  - `read_op(fmt)` – `*l`, `*L`, `*a`, numeric counts;
  - `write_op(...)` – concatenated `tostring` of arguments;
- synchronous helpers:
  - `read_string`, `read_all`, `read_exactly`, `write_string`, `flush_output`, `read`, `write`, `flush`.

These synchronous helpers use `fibers.perform` (via `fibers.performer.perform`), so they respect the current scope’s fail-fast and cancellation semantics when called from inside a fiber.

`Stream` itself does not depend on file descriptors or direct system calls. It only depends on:

- the abstract `StreamBackend`;
- the event algebra (`op`, `wait`);
- the scope-aware performer for synchronous helpers.

### 4.2 Poller and readiness

`fibers.io.poller.core` defines a `Poller`:

- holds two `Waitset`s:
  - `rd` – tasks waiting for read readiness on an fd;
  - `wr` – tasks waiting for write readiness on an fd;
- exposes `wait(fd, "rd"/"wr", task)`:
  - adds the task to the appropriate waitset;
  - calls backend `on_wait_change` if provided, so kernels can update interest sets.

As a task source:

- `Poller:schedule_tasks(sched, now, timeout)`:
  - converts the timeout to milliseconds;
  - calls backend `poll(backend_state, timeout_ms, rd_waitset, wr_waitset)`;
  - for each fd with events, notifies `rd` and/or `wr` waiters;
  - recomputes interest masks.

The `Poller` module (`fibers.io.poller`) chooses a backend at load time from:

- `fibers.io.poller.epoll` – Linux epoll backend via FFI;
- `fibers.io.poller.select` – luaposix-based poll/select backend.

Both implement:

- `new_backend()`;
- `poll(state, timeout_ms, rd_waitset, wr_waitset)`;
- optional `on_wait_change`, `close_backend`, `is_supported`.

The scheduler registers the `Poller` singleton as a task source, and calls its `schedule_tasks` method when needed.

### 4.3 FD backends, files and sockets

`fibers.io.fd_backend.core` defines a generic `FdBackend`:

- wraps a platform handle (typically a file descriptor);
- implements methods compatible with `StreamBackend`:
  - `read_string(max)` / `write_string(str)`;
  - `seek(whence, off)`;
  - `on_readable(task)` / `on_writable(task)` via the poller;
  - `close()`.

It also defines module-level helpers:

- file-level:
  - `open_file(path, mode, perms)`;
  - `pipe()`;
  - `mktemp(prefix, perms)`;
  - `fsync(fd)`;
  - `rename(old, new)`;
  - `unlink(path)`;
  - `decode_access(flags)` (read/write from open flags);
  - `ignore_sigpipe()`;

- socket-level:
  - `socket(domain, stype, protocol)`;
  - `bind(fd, sa)`;
  - `listen(fd)`;
  - `accept(fd)` (non-blocking, with “would block” signalling);
  - `connect_start(fd, sa)`;
  - `connect_finish(fd)`.

Two concrete backends are provided and selected by `fibers.io.fd_backend`:

- `fd_backend.ffi`:
  - uses FFI to call libc functions (`read`, `write`, `open`, `socket`, etc.);
  - provides Unix-style modes and permissions;
  - includes AF_UNIX socket support.

- `fd_backend.posix`:
  - uses luaposix (`posix.unistd`, `posix.fcntl`, `posix.sys.socket`, etc.);
  - provides equivalent functionality without FFI.

### 4.4 Top-level file and socket modules

`fibers.io.file` builds on `Stream` and `FdBackend`:

- `fdopen(fd, flags_or_mode, filename?)`:
  - wraps a numeric fd and a mode (numeric flags, string, or table) into a `Stream`;
  - uses `fd_backend.new(fd, { filename = filename })` as the `StreamBackend`;
  - sets readable/writable according to the mode (via `mode_access` or backend `decode_access`).

- `open(filename, mode?, perms?)`:
  - uses backend `open_file`;
  - wraps the resulting fd via `fdopen`.

- `pipe()`:
  - uses backend `pipe()` and wraps the read and write ends as separate streams.

- `mktemp(prefix, perms?)`:
  - uses backend `mktemp`.

- `tmpfile(perms?, tmpdir?)`:
  - creates a temporary file via `mktemp`;
  - wraps it as a `"r+"` stream via `fdopen`;
  - arranges for unlink-on-close by overriding backend `close`, with an opt-out via `stream:rename(newname)`.

- `init_nonblocking(fd)`:
  - delegates to backend `set_nonblock`.

`fibers.io.socket` uses `FdBackend` sockets:

- `socket(domain, stype, protocol?)` -> a `Socket` wrapper that:
  - ensures the fd is non-blocking;
  - exposes methods such as `listen_unix`, `accept_op`, `accept`, `connect_op`, `connect`, `connect_unix_op`, `connect_unix`, `close`.

- `listen_unix(path, opts?)`:
  - binds and listens on an AF_UNIX path;
  - optionally provides ephemeral semantics (unlink on close).

- `connect_unix(path, stype?, protocol?)`:
  - creates a socket, connects, and wraps the connection as a full-duplex `Stream`.

Underlying system calls are isolated in `FdBackend` implementations. The `file` and `socket` modules themselves see only:

- `FdBackend` functions such as `open_file`, `pipe`, `socket`, `bind`, `listen`, `accept`;
- the `Stream` abstraction.

They do not depend on any specific syscall API and do not call FFI or luaposix directly.

### 4.5 Process execution and ExecBackend

`fibers.exec` provides structured process execution with scope-bound lifetime.

A `Command` encapsulates a process configuration and its lifecycle. It is constructed via:

- `exec.command{ ...spec... }`; or
- `exec.command("prog", "arg1", "arg2", ...)` (positional argv).

The spec includes:

- `argv` – programme and arguments;
- `cwd` – working directory;
- `env` – environment overrides;
- `flags` – backend-defined flags (e.g. `setsid`);
- `stdin`, `stdout`, `stderr` – each of:
  - `"inherit"` – use the current process’ stdio for that stream;
  - `"null"` – redirect to/from `/dev/null`;
  - `"pipe"` – create a pipe (child side wired to the process, parent side exposed as a `Stream`);
  - for stderr only, `"stdout"` – share stdout’s configuration;
  - a `Stream` – user-supplied stream (not owned by the Command).

Internally, `fibers.exec` normalises these into `ExecStreamConfig` values and delegates to an `ExecBackend` selected by `fibers.io.exec_backend`:

- `ExecBackend.start(spec)` returns:
  - backend state (including `pid`);
  - streams (parent ends for any pipes created).

`Command` methods include:

- configuration setters (`set_stdin`, `set_stdout`, `set_stderr`, `set_cwd`, `set_env`, `set_flags`, `set_shutdown_grace`);
- introspection:
  - `status()` -> `CommandStatus`, code or signal, error;
  - `pid()`, `argv()`;
- signalling:
  - `kill(sig?)` – uses backend signalling; attempts a meaningful default if `sig` is nil;
- stream access:
  - `stdin_stream()`, `stdout_stream()`, `stderr_stream()`:
    - return `Stream`s for pipe-backed stdio;
    - enforce that pipes are created lazily by calling `_ensure_started()` if necessary.

Lifecycle Ops:

- `run_op()`:
  - ensures the process has been spawned;
  - waits on `backend:wait_op()` and updates command status;
  - returns `(status, code, signal, err)`.

- `shutdown_op(grace?)`:
  - attempts a polite termination (backend `terminate` or `send_signal`);
  - runs a `boolean_choice` between:
    - the process’ `run_op()`; and
    - `sleep.sleep_op(grace)` (default `DEFAULT_SHUTDOWN_GRACE`);
  - if the process does not exit in time:
    - attempts a more forceful kill (backend `kill` or `send_signal`);
    - performs `backend:wait_op()` to observe exit;
  - returns `(status, code, signal, err)`.

- `output_op()`:
  - if stdout is currently inherited and the command has not started, switches stdout to `"pipe"`;
  - ensures the process is started;
  - reads all of stdout via `stream:read_all_op()`;
  - waits for process completion via `run_op()`, using `perform_with_scope_or_raw` to respect scope semantics when appropriate;
  - returns `(string_output, status, code, signal, err)`.

- `combined_output_op()`:
  - rewires stderr to `"stdout"` (if not already a pipe/stream);
  - delegates to `output_op()`.

Scope integration:

- `exec.command` must be called from inside a fiber (it asserts `Runtime.current_fiber()`), and binds the `Command` to the current scope;
- the scope registers a `finally` handler that:
  - on scope exit:
    - performs a best-effort `shutdown_op`;
    - closes any owned stdio streams;
    - closes the backend state.

Actual process management is delegated to `ExecBackend` implementations via `fibers.io.exec_backend.core.build_backend`. Two are provided:

- `exec_backend.pidfd` (Linux pidfd-based, FFI):
  - uses `fork`, `execvp`, `pidfd_open`, and non-blocking `waitpid(WNOHANG)`;
  - uses the general poller (via pidfd) to integrate with the scheduler.

- `exec_backend.sigchld` (portable POSIX, luaposix-based):
  - uses `fork` and `execp`;
  - installs a SIGCHLD handler writing to a self-pipe;
  - runs a reaper task that:
    - drains the self-pipe;
    - uses `wait(WNOHANG)` to update per-pid state;
    - notifies waiters via a `Waitset`.

Both use the shared `exec_backend.stdio` module to:

- map `ExecStreamConfig` values to child and parent file descriptors;
- close child-only fds in the parent;
- build parent-side `Stream`s via `file.fdopen`.

As with files and sockets, `fibers.exec` itself does not call syscalls directly. It depends on:

- the `ExecBackend` abstraction;
- the `Stream` abstraction and scope/event machinery.

### 4.6 Portability and platform boundaries

Current backends are Unix-like:

- epoll and poll/select;
- POSIX-style file descriptors;
- fork/exec and signals;
- pidfd on Linux.

However:

- `fibers.io.stream`, `fibers.io.file`, `fibers.io.socket`, and `fibers.exec` are all written solely against internal abstract interfaces (`StreamBackend`, `FdBackend`, `ExecBackend`) and Ops;
- platform-specific details are confined to backend modules.

The intention is that additional platforms (for example, Windows) can be supported by:

- providing a `poller` backend using that platform’s event facilities;
- providing an `FdBackend` over native handles;
- providing an `ExecBackend` over the platform’s process APIs.

Application code using the top-level I/O and exec APIs should not need to change.

---

## 5. Error handling, cancellation and lifetimes

### 5.1 Fail-fast supervision

Error handling is organised around scopes:

- an uncaught error in any fiber:
  - is attributed to that fiber’s current scope;
  - causes the scope to transition from `"running"` to `"failed"` (if not already terminal);
  - triggers cancellation down the scope tree.

Users can still catch and handle expected errors locally. Unexpected errors bubble to scope boundaries by default.

### 5.2 Cancellation as an event

Cancellation is expressed as part of the event algebra:

- each scope has a cancellation condition;
- `Scope:not_ok_op()` and the internal `cancel_op(scope)` both reuse this condition to build Ops that become ready on cancellation;
- `Scope:run_op(ev)` races a user Op against cancellation;
- `Scope:sync` and `Scope:perform` enforce that operations in failed or cancelled scopes do not silently proceed.

The same pattern is used in the exec subsystem:

- shutdown races process exit against a timer and then escalates;
- `perform_with_scope_or_raw` ensures that exec helpers honour scope cancellation where appropriate, but can still complete shutdown once the owning scope is no longer running.

### 5.3 Finalisers and resource cleanup

Each scope maintains LIFO finalisers via `scope:finally(fn)`:

- run exactly once when the scope exits (after child fibers finish);
- can be used to:
  - close streams;
  - shut down child processes;
  - release other resources tied to the scope’s lifetime.

Errors in finalisers:

- convert `"ok"` into `"failed"` and record an error; or
- are appended to the scope’s collection of additional failures if the scope was already failed or cancelled.

`fibers.exec` uses this mechanism extensively to ensure that child processes are not left running beyond their scope.

---

## 6. Relationship to other models

### 6.1 Futures and async/await

In a typical futures/async model:

- work is represented as futures attached to specific operations;
- lifetime and cancellation are usually per-future concerns;
- structured concurrency is often added on top.

In this library:

- the primary representation is the **Op**;
- lifetime and cancellation are attached to **scope trees**, not individual operations;
- the same event algebra is used for:
  - channels and timers;
  - I/O readiness;
  - process completion;
  - scope completion and cancellation.

This avoids proliferating distinct abstractions for different kinds of waiting and simplifies expressing complex coordination patterns.

### 6.2 Go-style goroutines and channels

The combination of fibers and channels is similar in spirit to Go:

- both provide lightweight concurrent contexts;
- both provide channels for synchronous (and optionally buffered) communication.

However:

- there is no built-in language `select`; instead, selection is expressed via the event algebra (`choice` etc.);
- structured concurrency scopes provide explicit, enforced lifetime for groups of fibers;
- synchronous helpers (`fibers.perform`, stream methods, etc.) are scope-aware and respect fail-fast semantics.

### 6.3 Actor systems

The scope tree resembles a supervision tree in actor systems:

- failures propagate upwards and prompt cancellation of child scopes;
- work is grouped by lifetime rather than treated as isolated tasks.

The primary difference is that communication is via channels and streams rather than actor mailboxes, and there is a single scheduler (rather than one thread per actor).

---

## 7. Intended usage patterns

The following patterns are intended to be typical.

### 7.1 Application entry point

From non-fiber code:

- call `fibers.run(main_fn, ...)`.

Inside `main_fn(scope, ...)`:

- use `fibers.spawn(fn, ...)` to create child fibers under `scope`;
- use `fibers.run_scope`/`Scope.run` or `fibers.with_scope_op`/`Scope.with_op` to create further nested scopes where needed;
- perform Ops via:
  - `fibers.perform(ev)` (uses the current scope); or
  - `scope:perform(ev)` / `scope:sync(ev)`.

The process terminates when the main child scope of the root completes and the scheduler stops.

### 7.2 I/O services

Use the top-level modules:

- `fibers.io.file` for file streams and pipes;
- `fibers.io.socket` for AF_UNIX sockets (and any future socket types added by backends);
- `fibers.exec` for child processes;
- `fibers.channel` for in-memory communication;
- `fibers.sleep` for timers.

Avoid depending directly on platform-specific backends (`fd_backend`, `exec_backend`, poller backends) in application code. This keeps code portable and keeps platform concerns confined to backends.

### 7.3 Coordination and cancellation

Express waits and coordination in terms of the event algebra and scopes:

- use `op.choice` / `named_choice` / `boolean_choice` to race:
  - I/O readiness vs timeouts;
  - multiple channels or streams;
  - child process exit vs cancellation;

- bind logical units of work (requests, sessions, jobs) to their own scopes:
  - cancel the scope to cancel all associated work and resources;
  - use `scope:finally` to tie external resources to that scope.

---

## 8. Extension points and future work

The architecture is intended to be open to new backends and platforms.

### 8.1 Poller backends

To integrate a new kernel event mechanism:

- implement a backend module with:
  - `new_backend()`;
  - `poll(state, timeout_ms, rd_waitset, wr_waitset)`;
  - optional `on_wait_change`, `close_backend`, `is_supported`;

- add it to the candidate list in `fibers.io.poller`.

### 8.2 FD and stream backends

To support new handle types or platforms:

- implement an `FdBackend` using `fd_backend.core.build_backend(ops)` with:
  - `set_nonblock`, `read`, `write`, `seek`, `close`;
  - file helpers (`open_file`, `pipe`, `mktemp`, `fsync`, `rename`, `unlink`, `decode_access`, `ignore_sigpipe`);
  - optional socket helpers (`socket`, `bind`, `listen`, `accept`, `connect_start`, `connect_finish`);
  - optional metadata (`modes`, `permissions`, `AF_UNIX`, `SOCK_STREAM`).

Existing `file`, `socket`, and `stream` modules should operate unchanged.

### 8.3 Exec backends

To add process management on other platforms:

- implement an `ExecBackend` using `exec_backend.core.build_backend(ops)` with:
  - `spawn(spec)` -> backend state, parent streams, error;
  - `poll(state)` -> `done, code, signal, err`;
  - `register_wait(state, task, suspension, leaf_wrap)` -> `WaitToken`;
  - optional `send_signal`, `terminate`, `kill`, `close`, `is_supported`.

`fibers.exec` and `Command` then use this backend without modification.

### 8.4 Cross-platform targets

While current implementations target Unix-like platforms, the layering is designed so that:

- the public APIs for I/O and exec are independent of any particular syscall interface;
- backends encapsulate the dependencies on `epoll`, `select`, signals, and so on.

This is intentional to support future cross-platform work without changing the programming model.

---

## 9. Summary

The main design choices are:

- adopt a CML-style event algebra (Ops) as the common representation for all blocking behaviour;
- treat lifetimes (scopes, processes, I/O) as first-class events within that algebra;
- organise concurrent work into a tree of scopes with fail-fast supervision and structured cancellation;
- express channels, timers, I/O and processes uniformly in terms of Ops and scopes;
- keep top-level I/O and exec modules free of direct system-call dependencies and delegate those concerns to pluggable backends;
- make the default synchronous entry points (`fibers.perform`, stream methods, etc.) scope-aware, so they always reflect structured concurrency semantics when used from within fibers.

The intention is to provide a small, coherent foundation for building reliable concurrent systems, with clear lifetime and cancellation semantics and a clear separation between platform-neutral logic and platform-specific backends.
