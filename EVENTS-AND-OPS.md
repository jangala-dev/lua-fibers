# Events and Ops

This document is about the library’s “event algebra”: **Ops** (`Op` values), the small set of combinators that glue them together, and how you execute them through the public `fibers` API.

Most users only need:

* `fibers.perform(op)` — run an op in the current fiber and scope (may block; may raise).
* `fibers.choice`, `fibers.race`, `fibers.first_ready`,
  `fibers.named_choice`, `fibers.boolean_choice` — compose ops.
* `fibers.guard`, `fibers.with_nack`, `fibers.bracket` — build ops with structure and cleanup.
* ops from other modules (channels, sleep, streams, sockets, exec, scopes…), which all return `Op` values.

Lower-level tools live in `fibers.op` and `fibers.wait` and are mainly for people implementing new primitives.

---

## 1. What is an `Op`?

An `Op` is a *description* of something that may block.

You can:

* **perform** it (a fiber may suspend and later resume),
* **compose** it (races, timeouts, multi-way waits, structured cleanup),
* and let it be **interrupted by scope cancellation**.

The key idea is: you do not “do blocking work”. You construct an op that *represents* the blocking work, then you combine/perform it.

Examples of ops you’ll see in normal code:

* Channels: `ch:get_op()`, `ch:put_op(value)`
* Timers: `sleep.sleep_op(dt)`, `sleep.sleep_until_op(t)`
* Streams: `stream:read_line_op()`, `stream:write_string_op("...")`
* Sockets: `sock:accept_op()`, `sock:connect_op(addr)`
* Processes: `cmd:run_op()`, `cmd:output_op()`
* Scopes: `scope:join_op()`, `scope:not_ok_op()`

They’re all the same *kind* of thing: an `Op` value.

---

## 2. Performing operations

The usual way to execute an op is:

```lua
local fibers = require "fibers"

fibers.run(function(scope)
  local ch = require("fibers.channel").new()

  fibers.spawn(function()
    ch:put("hello from child")  -- Channel:put performs internally
  end)

  local msg = fibers.perform(ch:get_op())
  print("got:", msg)
end)
```

Important points:

* `fibers.perform(op)` must be called from inside a running fiber (inside `fibers.run`, or inside a function started with `fibers.spawn`).
* It runs under the **current scope**. If the scope fails or is cancelled while you’re blocked, `perform` is interrupted according to scope semantics (see your structured concurrency docs).
* Many modules also provide convenience methods (`Channel:get()`, `Stream:read_line()`, etc.) which simply do `perform(self:..._op())`.

You may see `op.perform_raw` or `scope:perform` internally. Treat `fibers.perform` as the public entry point.

---

## 3. Core combinators (top-level API)

The `fibers` module re-exports the main op constructors and combinators:

```lua
local fibers = require "fibers"

-- Constructors / guards
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

All of these take `Op` values and return new `Op` values.

### 3.1 `always` and `never`

```lua
local ev1 = fibers.always(42, "ok")  -- immediately ready
local ev2 = fibers.never()           -- never becomes ready
```

* `always(...)` is an op that completes immediately with the given values.
* `never()` is an op that never completes (useful for tests and placeholder wiring).

### 3.2 `choice`: the workhorse

```lua
local ev = fibers.choice(
  ch:get_op(),
  sleep.sleep_op(5.0)
)

local result = fibers.perform(ev)
```

`fibers.choice(e1, e2, ...)` builds an op that:

* waits until at least one arm can complete,
* picks one ready arm (if several are ready, selection is implementation-defined),
* completes with that arm’s results,
* and **aborts the non-winning arms** so they can clean up registrations/reservations.

That last part matters more than it looks: it is how you avoid “timeout races” leaving stale I/O registrations behind, or leaving “I was waiting for X” state lying around in a channel/queue/poller.

### 3.3 `race` and `first_ready`

These are convenience wrappers around `choice`.

* `fibers.race(e1, e2, ...)` reads as “whichever finishes first”.
* `fibers.first_ready(list)` is for polling-style patterns (when you’re selecting among readiness operations and want the first one that can make progress).

Both behave like `choice`: one winner, losers aborted, scope cancellation still applies.

### 3.4 `named_choice`: label the winner

```lua
local lines_op = fibers.named_choice{
  stdout = out_stream:read_line_op(),
  stderr = err_stream:read_line_op(),
}

local which, line, err = fibers.perform(lines_op)

if which == "stdout" then
  -- handle stdout
elseif which == "stderr" then
  -- handle stderr
end
```

`fibers.named_choice{ name = op, ... }` performs like `choice`, but returns:

1. the winning key, then
2. that arm’s results.

This pattern is used by helpers like `stream.merge_lines_op`.

### 3.5 `boolean_choice`: two-way, with a flag

```lua
local ev = fibers.boolean_choice(
  cmd:run_op(),
  sleep.sleep_op(5.0)
)

local is_exit, status, code, signal, err = fibers.perform(ev)

if is_exit then
  -- process finished
else
  -- timeout
end
```

`fibers.boolean_choice(a, b)` returns:

* `true, ...` if `a` won
* `false, ...` if `b` won

It’s a nice fit for “operation vs timeout” and “try X, otherwise do Y” flows.

---

## 4. Guard, bracket, and nacks

### 4.1 `guard`: build ops at performance time

`guard` delays construction until the moment the op is actually performed:

```lua
local ev = fibers.guard(function()
  return ch:get_op()
end)
```

Why this exists:

* you may need to capture dynamic context (current scope, current time, current state),
* you may need fresh internal state per synchronisation (tokens, registrations),
* you want the same op “shape” to be reusable without leaking per-run state.

Many primitives use `guard` internally to keep state per-perform rather than per-definition.

### 4.2 `bracket`: resource safety at the op level

```lua
local ev = fibers.bracket(
  function()                 -- acquire
    return connect_somewhere()
  end,
  function(sock, aborted)    -- release
    if aborted then sock:close() else sock:shutdown() end
  end,
  function(sock)             -- use
    return sock:read_line_op()
  end
)

local line = fibers.perform(ev)
```

`fibers.bracket(acquire, release, use)`:

* runs `acquire()` once the operation commits,
* passes the resource to `use(resource)` to produce the body op,
* guarantees `release(resource, aborted)` runs exactly once:

  * `aborted == false` if the body completes normally,
  * `aborted == true` if the operation is aborted (e.g. loses a `choice`) or the scope is cancelled.

Think of it as “finally, but composable with races”.

### 4.3 `with_nack`: “tell me if I lose”

`with_nack` is a specialised tool for ops that must hear “you didn’t win” promptly:

```lua
local ev = fibers.with_nack(function(nack_op)
  -- build and return an Op
  -- if this op loses a choice, nack_op becomes ready
end)
```

Typical uses:

* registrations that should be cancelled quickly if abandoned,
* protocols where a losing branch must send “never mind” to another party.

Most users will not need this directly; it is mainly for robust primitive implementation.

---

## 5. Ops, scopes, and cancellation

Scopes are the lifetime boundary. Ops are the waiting boundary. They meet at `fibers.perform`.

What you can rely on:

* `fibers.perform(op)` runs under the current scope.
* If the scope is cancelled or fails, blocked ops are interrupted (cancellation participates in the same event algebra as other ops).
* Composite ops (`choice` et al.) abort losing arms, so primitives can reliably unregister interest and clean up.

A useful shift in style: instead of catching cancellation around `perform`, prefer to let it propagate and put cleanup in `finally`/`bracket`/scope finalisers. That keeps “who owns what” obvious.

If you need an explicit boundary that *returns* status rather than raising, use `fibers.run_scope` or `fibers.run_scope_op` — that is the intended place where errors become values.

---

## 6. Implementing new primitives (overview)

Most application code never touches this section. If you are implementing new blocking primitives, you will usually use:

* `fibers.op` for low-level op construction (`new_primitive`, `:wrap`, `:on_abort`, …)
* `fibers.wait.waitable` to bridge “non-blocking step + registration” into an op

The standard pattern:

```lua
local wait = require "fibers.wait"

local function my_primitive_op(...)
  local function step()
    -- Non-blocking probe:
    --   return true, ...results... if ready
    --   return false              if not ready yet
  end

  local function register(task, suspension, leaf_wrap)
    -- Arrange for task:run() to be called when progress may have been made.
    -- Return a token with optional token:unlink() to cancel registration.
  end

  return wait.waitable(register, step)
end
```

Using `waitable` gets you a lot “for free”:

* the op participates correctly in `choice`/`race`/`named_choice`,
* losing a choice triggers abort, and abort triggers `unlink` (so you do not leak registrations),
* the scheduler/poller can wake you efficiently without blocking the event loop.

For users of the library, the takeaway is simple:

> If something blocks in this library, it’s an `Op`.
> If it’s an `Op`, it composes with choice, timeouts, cancellation, and cleanup.

That is the whole trick.
