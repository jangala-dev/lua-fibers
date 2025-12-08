# Events and Ops

This document describes the event algebra used by the library: how operations (`Op`s) are represented, how to compose them, and how to execute them through the top-level `fibers` module.

The emphasis here is on the public entry points exported from:

```lua
local fibers = require "fibers"
````

Most users will only need:

* `fibers.perform(op)` – execute an operation in the current fiber and scope.
* `fibers.choice`, `fibers.race`, `fibers.first_ready`,
  `fibers.named_choice`, `fibers.boolean_choice` – compose operations.
* `fibers.guard`, `fibers.with_nack`, `fibers.bracket` – build structured, cancellable operations.
* Operations provided by other modules (channels, sleep, streams, exec, etc.) which return `Op` values.

Lower-level construction utilities live in `fibers.op` and `fibers.wait` and are primarily intended for implementers of new primitives.

---

## 1. What is an `Op`?

An `Op` is a *description* of a potentially blocking operation that can be:

* Performed by a fiber (which may suspend and resume).
* Composed with other operations (races, timeouts, structured cleanup).
* Observed by scope cancellation (so that a cancelled scope can interrupt it).

You do **not** perform raw I/O or sleep directly; instead you obtain an `Op` from a primitive and then pass it to the event algebra or to `fibers.perform`.

Examples:

* Channels: `ch:get_op()`, `ch:put_op(value)`
* Timers: `sleep.sleep_op(dt)`
* Streams: `stream:read_line_op()`, `stream:write_string_op("...")`
* Processes: `cmd:run_op()`, `cmd:output_op()`
* Scopes: `scope:join_op()`, `scope:done_op()`

These all return `Op` values.

---

## 2. Performing operations

The usual way to execute an operation is via the top-level `perform` helper:

```lua
local fibers = require "fibers"

fibers.run(function(scope)
  local ch = require "fibers.channel".new()
  fibers.spawn(function(child_scope)
    ch:put("hello from child")      -- uses channel’s own perform()
  end)

  local msg = fibers.perform(ch:get_op())
  print("got:", msg)
end)
```

Key points:

* `fibers.perform(op)` must be called from inside a running fiber (for example, inside `fibers.run` or a function launched with `fibers.spawn`).
* It obeys the current scope’s cancellation rules: if the enclosing scope is cancelled or fails, the blocked `perform` will be interrupted according to the scope semantics (see `STRUCTURED-CONCURRENCY.md`).
* Most higher-level modules provide their own convenience wrappers (for example, `Channel:get()` calls `perform(self:get_op())` internally).

In lower-level code you may see `op.perform_raw(op_value)` or `scope:perform(op_value)`; the intended public surface is `fibers.perform`.

---

## 3. Core combinators (top-level API)

The `fibers` module re-exports the main combinators from `fibers.op`:

```lua
local fibers = require "fibers"

-- Constructors and guards
fibers.always(...)
fibers.never()
fibers.guard(build_fn)
fibers.with_nack(build_fn)
fibers.bracket(acquire, release, use)

-- Choices
fibers.choice(...)
fibers.race(...)
fibers.first_ready(...)
fibers.named_choice(table_of_ops)
fibers.boolean_choice(op1, op2)
```

These all work with `Op` values and return new composite `Op` values.

### 3.1 `always` and `never`

```lua
local ev1 = fibers.always(42, "ok")  -- immediately ready
local ev2 = fibers.never()           -- never becomes ready
```

* `fibers.always(...)` creates an `Op` that is immediately ready and, when performed, returns the given values without blocking.
* `fibers.never()` creates an `Op` that never completes. It is mainly useful in tests and as a placeholder.

These are often used in wrappers and default behaviours, for example where a primitive needs to return a success result without waiting.

### 3.2 `choice`

```lua
local ev =
  fibers.choice(
    ch:get_op(),                 -- receive from a channel
    sleep.sleep_op(5.0)          -- or time out after 5 seconds
  )

local result = fibers.perform(ev)
```

`fibers.choice(e1, e2, ...)` builds an operation that:

* Waits until at least one of the argument operations can complete.
* Chooses one of the ready operations (if several are ready, the choice is implementation-defined).
* Completes with the chosen operation’s results.
* Ensures that the non-chosen operations are aborted, so that they can clean up any registrations or reservations.

`choice` is the basic building block for races, timeouts, and multi-way wait patterns.

### 3.3 `race` and `first_ready`

`race` and `first_ready` are convenience wrappers around `choice`, tailored to common patterns:

* `fibers.race(e1, e2, ...)` – race several events and get the winner’s result. It is a thin wrapper over `choice`, intended for readability when you only care about “whichever completes first”.
* `fibers.first_ready(e1, e2, ...)` – a helper for situations where you are polling a set of readiness operations and want the first that can make progress. It is also built on top of `choice`.

In both cases the exact return shape follows the underlying events. They participate in cancellation and abort in the same way as `choice`.

### 3.4 `named_choice`

`named_choice` labels branches:

```lua
local lines_op = fibers.named_choice{
  stdout = out_stream:read_line_op(),
  stderr = err_stream:read_line_op(),
}

local which, line, err = fibers.perform(lines_op)

if which == "stdout" then
  -- handle stdout line
elseif which == "stderr" then
  -- handle stderr line
end
```

`fibers.named_choice{ name1 = ev1, name2 = ev2, ... }` builds an `Op` that, when performed:

* Chooses one of the arms using the same rule as `choice`.
* Returns:

  * the key (`name`), and
  * the chosen operation’s results.

Unchosen arms are aborted as with `choice`.

This pattern is used in `fibers.io.stream.merge_lines_op`.

### 3.5 `boolean_choice`

`boolean_choice` is a two-way choice that returns a Boolean indicating which arm completed:

```lua
local ev = fibers.boolean_choice(
  cmd:run_op(),                  -- process finished
  sleep.sleep_op(5.0)            -- timeout
)

local is_exit, status, code_or_sig, err = fibers.perform(ev)

if is_exit then
  -- process finished; status/code_or_sig/err describe outcome
else
  -- timeout; you might now send a termination signal or similar
end
```

`fibers.boolean_choice(ev1, ev2)` builds an `Op` that:

* Races `ev1` against `ev2`.
* When performed, returns:

  * a Boolean flag `true` if `ev1` won, `false` if `ev2` won, followed by
  * the chosen operation’s results.

This is convenient for patterns such as “operation vs timeout”.

---

## 4. Guard, bracket and nacks

### 4.1 `guard`

`guard` delays construction of an operation until the moment it is performed:

```lua
local ev = fibers.guard(function()
  -- Runs each time ev is performed, in the current fiber and scope.
  return ch:get_op()
end)
```

This is used to:

* Capture the *current* dynamic context (scope, fiber, cancellation state).
* Create fresh internal state for every synchronisation (for example, a token or registration handle).
* Ensure that composite operations remain reusable; you can compile an `Op` once and perform it many times, each time with fresh internal state.

Internally, many primitives use `guard` to wrap their low-level logic.

### 4.2 `bracket`

`bracket` provides structured resource management at the level of operations:

```lua
local ev = fibers.bracket(
  function()                     -- acquire
    local sock = connect_somewhere()
    return sock
  end,
  function(sock, aborted)        -- release
    if aborted then
      sock:close()
    else
      sock:shutdown()
    end
  end,
  function(sock)                 -- use
    return sock_stream(sock):read_line_op()
  end
)

local line = fibers.perform(ev)
```

`fibers.bracket(acquire, release, use)`:

* Runs `acquire()` once the operation is actually committed to run.
* Passes the acquired resource to `use`, which must return an `Op` describing the body.
* Guarantees that `release(resource, aborted)` is called exactly once:

  * with `aborted == false` if the body completes normally;
  * with `aborted == true` if the operation is aborted (for example, loses a `choice`) or if the enclosing scope is cancelled.

This is the event-level equivalent of `pcall`/`xpcall` with `finally` blocks and is heavily used in internal modules for safe registration and cleanup.

### 4.3 `with_nack`

`with_nack` is a specialised combinator for building abortable operations that need early notification when they *lose* a race.

In outline:

```lua
local ev = fibers.with_nack(function(nack_op)
  -- Construct and return an Op.
  -- If this Op participates in a choice and *loses*, nack_op will
  -- be performed so you can cancel any outstanding work.
end)
```

Typical uses include:

* Registering with an external system (for example, an I/O multiplexer or a remote service) with a way to cancel that registration if the operation is abandoned.
* Building higher-level protocols where a losing branch needs to send a “never mind” message.

Most users will not need `with_nack` directly; it is primarily an implementation tool for robust primitives.

---

## 5. Interaction with scopes and cancellation

Scopes (see `STRUCTURED-CONCURRENCY.md`) represent supervised lifetime domains. Operations and scopes interact as follows:

* When you call `fibers.perform(op)` inside a fiber, the library ensures that:

  * The operation runs under the current scope.
  * If the scope is cancelled or fails, the operation is aborted (for example, choices are resolved in favour of the scope’s cancellation `Op`).
* Many primitives expose scope-aware wrappers:

  * `scope:run_op(ev)` wraps an operation so that it observes that scope’s cancellation.
  * `scope:perform(ev)` executes an operation under that scope and turns cancellation into a Lua error.

A common pattern is “operation or cancellation, whichever first”:

```lua
local scope  = fibers.current_scope()
local body   = ch:get_op()
local cancel = scope:done_op()

local ev = fibers.choice(body, cancel)

local ok, value_or_reason = pcall(function()
  return fibers.perform(ev)
end)
```

Internally, scope cancellation is itself represented as an `Op` which competes in the same event algebra as other operations.

---

## 6. Implementing new primitives (overview)

Most application code only needs the top-level `fibers` entry points. If you are implementing new primitives, you will usually work with:

* `fibers.op` – low-level event constructors (`new_primitive`, `on_abort`, etc.).
* `fibers.wait.waitable` – helper for building operations driven by non-blocking `step` functions and registration callbacks.

The standard pattern is:

```lua
local op   = require "fibers.op"
local wait = require "fibers.wait"

local function my_primitive_op(...)
  local function step()
    -- Non-blocking check:
    -- return true, ...results... if ready;
    -- return false if not yet ready.
  end

  local function register(task, suspension, leaf_wrap)
    -- Arrange for task:run() to be called when progress may have been made.
    -- Return a token with an optional token:unlink() for cancellation.
  end

  return wait.waitable(register, step)
end
```

By building on `waitable` and the combinators described above, your new primitive will automatically:

* Participate correctly in `choice`, `race`, `named_choice`, etc.
* Respond properly to aborts (losing a race) and scope cancellation.
* Integrate with the scheduler and poller without blocking the event loop.

For most users, the important point is that every blocking building block in this library exposes its behaviour as an `Op`. You can then reason about and combine these operations declaratively using the small algebra described above, rather than manually managing callbacks, state machines or ad-hoc flags.

---
