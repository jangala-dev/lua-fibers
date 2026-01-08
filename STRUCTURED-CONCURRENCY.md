# Structured concurrency

This document describes how the library organises concurrent work using *scopes*, and how to use the top-level API in `fibers.lua` to manage lifetimes, failure, and cancellation.

The focus is on:

* `fibers.run`
* `fibers.spawn`
* `fibers.run_scope`
* `fibers.run_scope_op`
* `fibers.current_scope`
* `fibers.perform` and `fibers.try_perform`

Lower-level details of the scheduler and the op algebra are covered elsewhere.

---

## 1. Overview

The library uses structured concurrency:

* Every fiber runs inside a *scope*.
* Scopes form a tree: a scope may have child scopes.
* The first non-cancellation fault in a scope becomes the **primary failure** for that scope and triggers **fail-fast cancellation** of that scope and its descendants.
* Scopes provide deterministic finalisation: attached child scopes are joined in attachment order, and finalisers run in LIFO order.

A scope is a supervision context. It owns a set of fibers and resources, and it reaches a terminal state only once its obligations have drained and its finalisers have run.

---

## 2. Top-level API

### 2.1 `fibers.run(main_fn, ...)`

```lua
local fibers = require 'fibers'

fibers.run(function(scope, ...)
  -- scope is a root-attached scope for this run
end)
```

* Creates the scheduler and the process root scope.
* Runs `main_fn(scope, ...)` inside a fresh child scope beneath the root.
* Drives the scheduler until that child scope reaches a terminal state and joins.
* On success, returns the values returned by `main_fn`.
* On failure or cancellation, raises the primary error / reason to the calling thread.

`fibers.run` must be called from outside any fiber.

### 2.2 `fibers.spawn(fn, ...)`

```lua
fibers.run(function(scope)
  fibers.spawn(function()
    local s = fibers.current_scope()
    -- ...
  end)
end)
```

* Spawns a new fiber under the **current scope**.
* Calls `fn(...)` in that fiber.
* Returns immediately; lifetime is managed via the scope (no join handle).

### 2.3 `fibers.run_scope(body_fn, ...)`

`fibers.run_scope` is a re-export of `Scope.run`.

```lua
local fibers = require 'fibers'

fibers.run(function()
  local st, rep, a, b = fibers.run_scope(function(child_scope, x)
    fibers.spawn(function()
      -- runs under child_scope
    end)
    return x, 42
  end, "value")

  if st == "ok" then
    -- a == "value", b == 42
  else
    -- on "failed"/"cancelled": a is the primary (error or reason)
  end
end)
```

Behaviour:

* Must be called from inside a fiber.
* Creates a new child scope of the current scope.
* Spawns a fiber in that child scope to run `body_fn(child_scope, ...)`.
* Joins the child scope deterministically and returns:

  ```lua
  status :: "ok" | "failed" | "cancelled"
  report :: ScopeReport
  ...    :: results from body_fn (only when status == "ok")
           OR primary value (only when status ~= "ok")
  ```

The `ScopeReport` has the shape:

```lua
report.id           -- scope id
report.extra_errors -- array of secondary errors (see section 3)
report.children     -- array of child outcomes (joined children)
```

Each `child` outcome contains:

```lua
child.id
child.status   -- "ok"|"failed"|"cancelled"
child.primary
child.report   -- nested ScopeReport
```

### 2.4 `fibers.run_scope_op(body_fn, ...)`

`fibers.run_scope_op` is a re-export of `Scope.run_op`.

This returns an `Op` which, when performed, runs `body_fn` in a fresh child scope and resolves when that child scope joins.

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function work_op()
  return fibers.run_scope_op(function(s)
    fibers.perform(sleep.sleep_op(1.0))
    return "done"
  end)
end

fibers.run(function()
  local st, rep, v_or_primary = fibers.perform(work_op())
  -- st is "ok"/"failed"/"cancelled"
end)
```

Key points:

* The child scope is cancelled and joined deterministically if the op is aborted as a losing arm in an outer `choice`.
* This is the supported way to make “run a structured sub-task” participate in the op algebra (timeouts, races, etc.).

### 2.5 `fibers.current_scope()`

```lua
local s = fibers.current_scope()
```

* Inside a fiber: returns the scope associated with that fiber (defaults to the root if none is set).
* Outside a fiber: returns the process root scope.

Most user code receives scopes as parameters (e.g. from `fibers.run` or `fibers.run_scope`). `fibers.current_scope()` is useful when you need access to the scope without threading it through arguments.

### 2.6 `fibers.perform(op)` and `fibers.try_perform(op)`

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function()
  fibers.perform(sleep.sleep_op(0.5))
end)
```

* `fibers.perform(op)` performs an `Op` under the current scope:

  * returns results on success;
  * raises on failure; and
  * raises a cancellation sentinel on cancellation.
* `fibers.try_perform(op)` performs under the current scope but returns status-first:

  ```lua
  st, ... = fibers.try_perform(op)
  -- st is "ok"|"failed"|"cancelled"
  ```

If you need to distinguish cancellation from failure when catching errors, use the helpers exposed by `fibers.scope` (`is_cancelled`, `cancel_reason`) unless you choose to re-export them from `fibers.lua`.

---

## 3. Scope lifecycle and reporting

A scope has two related notions of “status”:

* **Observational status** from `scope:status()`:

  ```lua
  "running"
  "failed", primary
  "cancelled", reason
  "ok" (only after join completes)
  ```

* **Terminal status** (used by `join_op`, `run`, `run_op`): `"ok"|"failed"|"cancelled"` with failure taking precedence if both a failure and cancellation are recorded.

### 3.1 Primary failure and secondary errors

* The first non-cancellation fault becomes `_failed_primary` and triggers cancellation of the scope.
* Any subsequent faults (including failures in finalisers and late-arriving fiber errors) are recorded in `report.extra_errors`.

This is deliberately conservative: the primary error answers “what caused this scope to fail”, and the report provides additional diagnostics without changing the primary cause.

---

## 4. Resource management with finalisers

Finalisers are registered with:

```lua
scope:finally(function(aborted, status, primary_or_nil)
  -- cleanup work
end)
```

Finalisers run during join, after:

1. spawned fibers in the scope have drained;
2. attached child scopes have been joined (in attachment order).

Finaliser calling convention:

* `aborted` is `true` when terminal status is not `"ok"`;
* `status` is `"ok"|"failed"|"cancelled"`;
* `primary_or_nil` is provided only when `status == "failed"` (cancellation is not treated as failure for this argument).

If a finaliser raises:

* if the scope was otherwise `"ok"`, the finaliser error becomes the primary failure for the scope;
* otherwise the error is recorded in `extra_errors` and the primary remains unchanged.

---

## 5. Cancellation and operations

Operations integrate with scopes through `scope:try_op` and the top-level performers:

* If the scope is already failed or cancelled, `try_op` resolves immediately with `"failed"` or `"cancelled"`.
* Otherwise, the operation races against the scope’s “not ok” condition.
* After completion, the scope is checked again; if it transitioned while the operation completed, the result is treated as not ok.

In practice:

* use `fibers.perform(op)` for direct-style code (raise-on-not-ok);
* use `fibers.try_perform(op)` or `scope:try(op)` when you want to handle failure/cancellation as data.

---

## 6. Example: structured workers with explicit outcome

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function run_workers(n)
  return fibers.run_scope(function(scope)
    for i = 1, n do
      fibers.spawn(function(idx)
        fibers.perform(sleep.sleep_op(0.1 * idx))
        if idx == 3 then
          error("worker " .. idx .. " failed")
        end
      end, i)
    end
  end)
end

fibers.run(function()
  local st, rep, v_or_primary = run_workers(5)

  if st == "ok" then
    print("all workers completed")
  elseif st == "failed" then
    print("failed:", v_or_primary)
  else
    print("cancelled:", v_or_primary)
  end

  if rep and rep.extra_errors and #rep.extra_errors > 0 then
    print("secondary errors:", table.concat(rep.extra_errors, "; "))
  end
end)
```

---

## 7. Example: racing a structured task against a timeout

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function task_op()
  return fibers.run_scope_op(function(scope)
    fibers.perform(sleep.sleep_op(2.0))
    return "done"
  end)
end

fibers.run(function()
  local st, rep, v_or_primary = fibers.perform(
    fibers.boolean_choice(
      task_op(),
      sleep.sleep_op(0.5):wrap(function() return "timeout" end)
    )
  )
  -- Interpret results based on the op you chose to race.
end)
```

(How you tag results is up to you; the key point is that `run_scope_op` composes as an `Op`.)

---

## 8. Unscoped errors

Most user code runs inside scopes created through `fibers.run`, `fibers.spawn`, and `fibers.run_scope`.

The runtime can still encounter fibers that are not associated with a scope (for example, internal fibers or externally spawned fibers that do not install scope attribution). Uncaught errors from such fibers are passed to the unscoped error handler:

```lua
fibers.set_unscoped_error_handler(function(fib, err)
  -- fib is the runtime fiber object
  -- err is the error value
end)
```

The default handler writes to stderr.

---

## 9. Summary

* Use `fibers.run` once at the top level.
* Use `fibers.spawn` to start concurrent fibers under the current scope.
* Use `fibers.run_scope` when you want a sub-task with its own scope and a status/report outcome.
* Use `fibers.run_scope_op` to race or compose a structured sub-task within the op algebra.
* Use `scope:finally` to attach resource cleanup to a scope’s lifetime.
* Use `fibers.perform` / `fibers.try_perform` to run ops so cancellation and failure follow the scope tree.

This keeps lifetimes bounded, failure and cancellation explicit, and cleanup deterministic.
