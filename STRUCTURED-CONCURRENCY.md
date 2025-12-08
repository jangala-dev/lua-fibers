# Structured concurrency

This document describes how the library organises concurrent work using *scopes*, and how to use the top-level API in `fibers.lua` to manage lifetimes, failure and cancellation.

The focus here is on the high-level entry points:

- `fibers.run`
- `fibers.spawn`
- `fibers.run_scope`
- `fibers.scope_op`
- `fibers.current_scope`
- `fibers.perform` (for running operations under the current scope)

Lower-level details of the scheduler and event algebra are covered elsewhere.

---

## 1. Overview

The library uses *structured concurrency*:

- Every fiber runs inside a *scope*.
- Scopes form a tree. A scope may have child scopes.
- Failures are tracked per scope and cause *fail-fast* cancellation of that scope and its children.
- Resources (streams, processes, etc.) are attached to scopes and cleaned up via defers when a scope finishes.

A useful way to think about this is:

> A scope is a supervision context. It owns a set of fibers and resources, and it finishes only when all of them have finished or been cancelled.

The top-level `fibers` module provides a convenient interface to this model.

---

## 2. Top-level API

### 2.1 `fibers.run(main_fn, ...)`

```lua
local fibers = require 'fibers'

fibers.run(function(scope, ...)
  -- scope is the top-level scope for this run
end)
````

* Creates the scheduler and a root supervision scope.
* Runs `main_fn(scope, ...)` inside a child scope of that root.
* Drives the scheduler until `main_fn`’s scope completes.
* On success, returns the values returned by `main_fn`.
* If the main scope fails or is cancelled, re-raises the primary error / reason in the calling thread.

`fibers.run` must be called from outside any fiber.

### 2.2 `fibers.spawn(fn, ...)`

```lua
fibers.run(function(scope)
  fibers.spawn(function()
    -- This runs under the same current scope as 'scope'
    local this_scope = fibers.current_scope()
    -- ...
  end)
end)
```

* Spawns a new fiber *under the current scope*.
* The function is called as `fn(...)`.
* If you need the scope inside the spawned fiber, call `fibers.current_scope()`.
* Returns immediately; there is no handle. Lifetime is managed via the scope.

This is the primary way to introduce concurrency under the current scope.

### 2.3 `fibers.run_scope(body_fn, ...)`

```lua
local status, err, defer_failures, result1, result2 = fibers.run_scope(function(child_scope, arg)
  -- child_scope is a new child of the current scope
  return "ok:" .. arg, 42
end, "value")
```

`fibers.run_scope` is a re-export of `Scope.run`:

* Must be called from inside a fiber.
* Creates a new *child scope* of the current scope.
* Spawns a fiber in that child scope to run `body_fn(child_scope, ...)`.
* Waits until the child scope reaches a terminal state.
* Returns:

  ```lua
  status         :: "ok" | "failed" | "cancelled"
  err            :: primary error or cancellation reason (nil when status == "ok")
  defer_failures :: array of additional errors from deferred handlers
  ...            :: results from body_fn (only when status == "ok")
  ```

This gives a way to treat a block of concurrent work as a value-returning operation, with explicit success/failure information. If the scope would otherwise have completed successfully, the first failing defer promotes the scope to `"failed"` and becomes the primary `err`; only subsequent defer errors are recorded in `defer_failures`.

### 2.4 `fibers.scope_op(build_op)`

```lua
local fibers = require 'fibers'

local scope_block_op = fibers.scope_op(function(child_scope)
  -- build and return an Op that uses child_scope
end)
```

`fibers.scope_op` is a re-export of `Scope.with_op`:

* Creates an `Op` that, when performed, runs a child scope as part of the operation.
* While the `Op` is running, that child scope is the current scope.
* When the `Op` completes or is aborted, the child scope is cancelled (if still running) and joined.

This allows “a block of structured concurrent work” to participate directly in the event algebra (for example in a `choice`).

### 2.5 `fibers.current_scope()`

```lua
local scope = fibers.current_scope()
```

Returns the current scope:

* Inside a fiber: the scope associated with that fiber (or the root if none is set).
* Outside a fiber: the current global scope (used mainly by the runtime).

In normal use you mostly receive scopes as parameters to `fibers.run`, `fibers.spawn`, and `fibers.run_scope`. `fibers.current_scope()` is useful when you need to access the scope without threading it through arguments.

### 2.6 `fibers.perform(op)`

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function(scope)
  fibers.perform(sleep.sleep_op(0.5))
end)
```

`fibers.perform` executes an `Op` in the current fiber, observing the current scope’s cancellation rules. Conceptually, it is equivalent to calling `scope:perform(op)` on the current scope.

Use `fibers.perform` for most operation execution.

---

## 3. Scope lifecycle and failure semantics

Each scope has a status:

* `"running"` – initial state.
* `"ok"` – scope completed successfully.
* `"failed"` – a fiber in the scope raised an error, or a defer handler failed.
* `"cancelled"` – scope was cancelled explicitly or by a parent’s failure.

Internally, a scope also tracks:

* a primary error or cancellation reason (`_error`), and
* any additional errors from deferred handlers in a list (`_defer_failures`).

### 3.1 How failures are recorded

If a fiber running in a scope raises a Lua error:

If a fiber running in a scope raises a Lua error while the scope is `"running"`:

* The scope records a failure, sets its status to `"failed"`, and stores that error as the primary error (if none is recorded yet).
* The scope then propagates cancellation to all child scopes.

Subsequent errors from other fibers in the same scope are treated as cancellation noise and are not accumulated.

Errors raised by deferred handlers are handled separately and are described in section 4.

### 3.2 How cancellation works

When a scope is cancelled:

* The scope status becomes `"cancelled"` (unless it is already `"ok"`).
* A cancellation reason is recorded (if none is present).
* Cancellation is propagated to child scopes.
* Any operations run under the scope via `fibers.perform` or `scope:perform` will complete with a cancellation error.

Cancellation can arise from:

* A direct call to `scope:cancel(reason)`.
* A failure in that scope or any ancestor scope.
* Aborting a scoped `Op` built with `fibers.scope_op`.

### 3.3 Observing scope status

Scopes passed into your functions support:

```lua
local status, err  = scope:status()
local defer_errors = scope:defer_failures()
local parent       = scope:parent()
local children     = scope:children()
```

These methods are mainly useful for diagnostics or building higher-level abstractions; most user code interacts via `fibers.run_scope` and `fibers.perform`.

---

## 4. Resource management with defers

Each scope maintains a LIFO list of deferred handlers, registered with:

```lua
scope:defer(function(s)
  -- cleanup work; s is the same scope
end)
```

Defers run when the scope transitions from `"running"` to a terminal state (`"ok"`, `"failed"`, `"cancelled"`):

* They run in reverse registration order (LIFO).
* If a defer raises an error:

  * If the scope was `"ok"`, it becomes `"failed"` and the defer’s error becomes the primary error.
  * Otherwise the error is added to the scope’s `defer_failures` list.

A typical pattern is to attach resources to the current scope:

```lua
local fibers = require 'fibers'
local file   = require 'fibers.io.file'

fibers.run(function(scope)
  local f, err = file.open("output.log", "w")
  if not f then error(err) end

  scope:defer(function()
    local ok, cerr = f:close()
    if not ok then
      error(cerr or "close failed")
    end
  end)

  fibers.perform(f:write_op("hello\n"))
end)
```

Many library components, such as process `Command` objects, register their own defers against the owning scope so that processes and pipes are cleaned up automatically when the scope ends.

---

## 5. Cancellation and operations

Operations (`Op`s) integrate with scopes through `fibers.perform` and, more directly, `scope:perform` / `scope:sync`:

* Before running an operation, the scope checks whether it is still `"running"`.
* While the operation is pending, a *cancellation operation* for the scope competes with the main operation in a `choice`.
* After the operation completes, the scope status is checked again; if the scope has failed or been cancelled, the call is treated as failed.

The common interface is:

```lua
local ok, result_or_err = scope:sync(op)
-- or
local result = scope:perform(op)  -- raises on failure/cancellation
-- or
local result = fibers.perform(op) -- uses the current scope
```

This means:

* Cancellations propagate predictably: when a parent scope fails, in-flight operations in child scopes will start to complete with cancellation errors.
* Code performing operations does not need to check the scope status manually; failure and cancellation are surfaced as return values or errors in a uniform way.

---

## 6. Running structured sub-tasks with `fibers.run_scope`

`fibers.run_scope` is useful when a piece of code needs to run a block of concurrent work and *decide what to do based on whether it succeeded, failed or was cancelled*.

Example: run a set of workers and treat failure as data rather than an exception at the top level.

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function run_workers(n)
  return fibers.run_scope(function(scope)
    for i = 1, n do
      fibers.spawn(function(idx)
        -- Each worker runs under the same child scope created by run_scope.
        local child_scope = fibers.current_scope()

        fibers.perform(sleep.sleep_op(0.1 * idx))
        if idx == 3 then
          error("worker " .. idx .. " failed")
        end
      end, i)
    end
  end)
end

fibers.run(function(scope)
  local status, err, defer_failures = run_workers(5)

  if status == "ok" then
    print("all workers completed successfully")
  elseif status == "failed" then
    print("workers failed with:", err)
  elseif status == "cancelled" then
    print("workers were cancelled:", err)
  end
end)
```

In this example:

* All workers share the same sub-scope created by `run_scope`.
* When worker 3 fails, that sub-scope becomes `"failed"` and cancels the others.
* `run_scope` returns `"failed", "worker 3 failed"` to the caller, which can handle it explicitly.
* The top-level `fibers.run` still sees the parent scope as `"ok"` because the failure was contained within the sub-scope.

---

## 7. Using scopes inside the event algebra with `fibers.scope_op`

Sometimes it is useful to treat “run this block of structured work” itself as an `Op`, for example to race it against a timeout.

`fibers.scope_op` supports this pattern:

```lua
local fibers = require 'fibers'
local op     = fibers  -- Op combinators re-exported here
local sleep  = require 'fibers.sleep'

local function timed_task_op(timeout_s)
  return op.race(
    -- Arm 1: run some work in its own scope
    fibers.scope_op(function(scope)
      return sleep.sleep_op(2.0)  -- placeholder for real work
    end),

    -- Arm 2: timeout
    sleep.sleep_op(timeout_s)
  )
end

fibers.run(function(scope)
  -- Race: either the scoped work completes or the timeout fires first.
  local which = fibers.perform(timed_task_op(0.5))
  print("winner arm:", which)
end)
```

Key points:

* `scope_op(build_op)`:

  * Captures the *current* scope as the parent.
  * When performed, creates a new child scope.
  * Temporarily sets the child scope as the current scope.
  * Runs the `Op` returned by `build_op(child_scope)` within that scope.
  * On completion or abort, cancels the child scope if still running and waits for it to finish.

* Because the child scope is integrated into the event algebra, structured work can be combined with other events (timeouts, channel operations, process waits) using `choice`, `race`, and related combinators.

---

## 8. Interaction with other modules

Structured concurrency underpins the rest of the library:

* **Channels and other primitives** expose operations (`*_op`) that you run using `fibers.perform`. The current scope’s cancellation rules apply to all of them.
* **I/O** (`fibers.io.stream`, `fibers.io.file`, `fibers.io.socket`) creates streams and sockets that are typically tied to the lifecycle of a scope via `scope:defer`.
* **Process execution** (`fibers.exec`) registers a defer on the owning scope to ensure processes are shut down and associated streams are closed when the scope exits.

As a result, an application built around scopes can use “scope ends” as the primary signal for cleaning up everything associated with that logical unit of work.

---

## 9. Unscoped errors

All normal user code should run in scopes created by `fibers.run`, `fibers.spawn`, and `fibers.run_scope`. Internally, the runtime may create fibers that are not initially associated with a scope. Errors from those fibers are attributed to the root scope by default.

The behaviour for *unscoped* fiber errors can be customised via:

```lua
fibers.set_unscoped_error_handler(function(fib, err)
  -- fib is the runtime fiber object
  -- err is the error value
end)
```

In most applications this is not required; errors in user code should normally be handled via scope failures and the return values from `fibers.run_scope` or the exception from `fibers.run`.

---

## 10. Summary

* Use `fibers.run` once at the top level to establish a supervising scope and scheduler.
* Use `fibers.spawn` to start fibers under the current scope.
* Use `fibers.run_scope` when you want a sub-task with its own scope and a `(status, err, ...)` result.
* Use `fibers.scope_op` when you need a scoped block to participate directly in `choice` and other event combinators.
* Use `scope:defer` to attach resource cleanup to the scope lifetime.
* Use `fibers.perform` to run operations so that cancellation and failure follow the scope tree.

This provides a disciplined way to structure concurrent programs so that lifetimes, failures and cleanup are explicit, bounded, and predictable.
