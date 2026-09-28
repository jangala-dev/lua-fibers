# Structured concurrency

This document explains how `fibers` organises concurrent work using **scopes**, and how the top-level API in `fibers.lua` helps you keep lifetimes, failure, cancellation, and cleanup on a short lead.

It covers:

* `fibers.run`
* `fibers.spawn`
* `fibers.run_scope`
* `fibers.run_scope_op`
* `fibers.current_scope`
* `fibers.perform`

It deliberately does **not** cover scheduler internals or the full op algebra. Think of this as “how to write code that behaves well under stress”.

---

## 1. Overview

`fibers` uses structured concurrency:

* Every fiber runs inside a **scope**.
* Scopes form a **tree**: a scope can have child scopes.
* The first non-cancellation fault in a scope becomes its **primary failure** and triggers **fail-fast cancellation** of the scope and its descendants.
* Scopes provide **deterministic finalisation**:

  * attached child scopes are joined in attachment order;
  * finalisers run in LIFO order.

A scope is a supervision context. It owns a set of running fibers and resources, and it only becomes “done” once:

1. its fibers have drained,
2. its child scopes have joined,
3. its finalisers have run.

If you remember one thing: *work should not outlive the scope that started it*.

---

## 2. Top-level API

## 2.1 `fibers.run(main_fn, ...)`

```lua
local fibers = require "fibers"

fibers.run(function(scope, ...)
  -- scope is a root-attached scope for this run
end)
```

`fibers.run`:

* must be called from **outside** any fiber;
* creates the scheduler and the process root scope;
* runs `main_fn(scope, ...)` inside a fresh child scope beneath the root;
* drives the scheduler until that child scope reaches a terminal state and joins.

Results:

* on success: returns the values returned by `main_fn`;
* on failure/cancellation: raises the **primary** error/reason to the calling thread.

This is the “one door in / one door out” boundary for your program.

---

## 2.2 `fibers.spawn(fn, ...)`

```lua
fibers.run(function(scope)
  fibers.spawn(function()
    local s = fibers.current_scope()
    -- ...
  end)
end)
```

`fibers.spawn`:

* spawns a new fiber under the **current scope**;
* calls `fn(...)` in that fiber;
* returns immediately.

There is no join handle. The scope owns the lifetime and joins deterministically.

---

## 2.3 `fibers.run_scope(body_fn, ...)`

`fibers.run_scope` is a re-export of `Scope.run`.

```lua
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

* must be called from inside a fiber;
* creates a fresh child scope of the current scope;
* runs `body_fn(child_scope, ...)` inside that scope;
* joins the child scope deterministically and returns:

```lua
status :: "ok" | "failed" | "cancelled"
report :: ScopeReport
...    :: results from body_fn        (only when status == "ok")
       :: primary error/reason value  (only when status ~= "ok")
```

`ScopeReport` shape:

```lua
report.id           -- scope id
report.extra_errors -- array of secondary errors
report.children     -- array of joined child outcomes
```

Child outcomes:

```lua
child.id
child.status   -- "ok"|"failed"|"cancelled"
child.primary
child.report   -- nested ScopeReport
```

Use `run_scope` when you want a clean boundary that turns “exceptions inside” into “status + report outside”.

---

## 2.4 `fibers.run_scope_op(body_fn, ...)`

`fibers.run_scope_op` is a re-export of `Scope.run_op`.

It returns an `Op` which, when performed, runs `body_fn` in a fresh child scope and resolves when that child scope joins.

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

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

* If this op loses as an arm in an outer `choice`, the child scope is cancelled (reason `"aborted"`) and then joined deterministically.
* This is the supported way to make “run a structured subtree” participate in the op algebra (timeouts, races, readiness, etc.).

If you find yourself wanting “spawn a big thing and maybe cancel it later”, this is usually the shape you want.

---

## 2.5 `fibers.current_scope()`

```lua
local s = fibers.current_scope()
```

* Inside a fiber: returns the scope associated with that fiber (defaults to the root if none is set).
* Outside a fiber: returns the process root scope.

Most code should accept scopes as parameters (from `fibers.run` or `fibers.run_scope`). `current_scope()` is for when threading a scope through arguments would be noise rather than clarity.

---

## 2.6 `fibers.perform(op)`

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

fibers.run(function()
  fibers.perform(sleep.sleep_op(0.5))
end)
```

`fibers.perform(op)`:

* performs an `Op` under the current scope;
* returns results on success;
* raises on failure;
* raises on cancellation.

This is deliberate: *inside a scope, “throw and unwind” is normal*. The scope boundary is where you translate exceptions into a status/report.

If you need status-first behaviour, use an explicit boundary:

* `fibers.run_scope(...)` (returns status/report/results),
* `fibers.run_scope_op(...)` (an op yielding status/report/results),
* or scope methods directly (for library code that is intentionally doing something special).

---

## 3. Scope lifecycle and reporting

A scope has two closely related notions of status:

### Observational status (`scope:status()`)

* `"running"`
* `"failed", primary`
* `"cancelled", reason`
* `"ok"` (only once join has completed)

This is a snapshot: useful for diagnostics, not a completion mechanism.

### Terminal status (what boundaries return)

Boundaries (`join_op`, `run`, `run_op`) return:

* `"ok" | "failed" | "cancelled"`

If both failure and cancellation are recorded, **failure wins**: cancellation is a consequence of failure (fail-fast), not a competing explanation.

---

## 3.1 Primary failure and secondary errors

Rules of the road:

* The first non-cancellation fault becomes the scope’s **primary failure** and triggers cancellation.
* Later faults (finalisers failing, late fiber errors, etc.) are recorded as **secondary errors** in `report.extra_errors`.

This is intentionally conservative:

* the primary answers “what caused this scope to stop being OK?”;
* the report answers “what else went wrong on the way out?”.

---

## 4. Resource management with finalisers

Finalisers attach cleanup to a scope’s lifetime:

```lua
scope:finally(function(aborted, status, primary_or_nil)
  -- cleanup work
end)
```

Finalisers run during join, after:

1. spawned fibers in the scope have drained,
2. attached child scopes have been joined (in attachment order).

Calling convention:

* `aborted` is `true` when terminal status is not `"ok"`;
* `status` is `"ok"|"failed"|"cancelled"`;
* `primary_or_nil` is provided only when `status == "failed"`.

If a finaliser raises:

* if the scope was otherwise `"ok"`, the finaliser error becomes the primary failure;
* otherwise it is recorded in `extra_errors` and the primary stays the same.

Practical advice: treat finalisers as “best-effort cleanup”, not as a second place to do real work.

---

## 5. Cancellation and operations

Scopes integrate with ops so cancellation and failure have real teeth:

* If a scope is already failed or cancelled, ops under it resolve as not-ok immediately (via the scope performer).
* Otherwise, a performed op implicitly races against the scope becoming not-ok.
* After the op completes, the scope is checked again; if the scope transitioned while the op was completing, the outcome is treated as not-ok.

What this means in practice:

* `fibers.perform(op)` is the default. It either gives you the result or unwinds the stack.
* Timeouts are written as op choice, not as “check a flag in a loop”.
* Losing arms in a `choice` are expected to clean up promptly (many primitives use abort hooks or unlink tokens so they stop waiting on fds, timers, etc.).

---

## 6. Example: structured workers with an explicit outcome

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

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

This style gives you one place to interpret outcomes: the boundary. Inside, workers just throw.

---

## 7. Example: racing a structured task against a timeout

The simplest “timeout” pattern is still the best one: race work against sleep.

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

local function task_op()
  return fibers.run_scope_op(function(scope)
    fibers.perform(sleep.sleep_op(2.0))
    return "done"
  end)
end

fibers.run(function()
  local which, st, rep, v_or_primary = fibers.perform(fibers.named_choice{
    task    = task_op(),         -- yields: st, rep, results/primary
    timeout = sleep.sleep_op(0.5),
  })

  if which == "timeout" then
    print("timed out; task scope cancelled and joined")
    return
  end

  if st == "ok" then
    print("task ok:", v_or_primary)
  else
    print("task not ok:", st, v_or_primary)
  end
end)
```

The important bit is not the tagging; it’s that `run_scope_op` makes “a whole subtree” act like a single op, with deterministic cleanup when it loses.

---

## 8. Unscoped errors

Most user code runs inside scopes created through `fibers.run`, `fibers.spawn`, and `fibers.run_scope`.

If the runtime encounters a fiber that is not associated with any scope (typically internal fibers or externally spawned ones), uncaught errors are sent to the unscoped error handler:

```lua
fibers.set_unscoped_error_handler(function(fib, err)
  -- fib is the runtime fiber object
  -- err is the error value
end)
```

The default handler writes to stderr.

If you see this handler firing in application code, it is usually a sign that something started work “off the books”.

---

## 9. Summary

* Use `fibers.run` once at the top level.
* Use `fibers.spawn` to start concurrent fibers under the current scope.
* Use `fibers.run_scope` for a structured subtree with a status/report outcome.
* Use `fibers.run_scope_op` when you want that subtree to participate in `choice` (timeouts, races, etc.).
* Use `scope:finally` (and op `bracket`/`:finally`) for cleanup.
* Use `fibers.perform` for waiting; let it throw, and interpret outcomes at boundaries.

This keeps lifetimes bounded, makes failure and cancellation meaningful, and makes cleanup predictable—even when things go wrong.
