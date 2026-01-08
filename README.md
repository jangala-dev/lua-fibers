# fibers

`fibers` is a small library for running many concurrent tasks in one Lua process, with:

- structured lifetimes (supervision scopes),
- cancellable operations (“Ops”),
- integrated I/O and subprocess handling.

It is intended for Lua programs that need high levels of concurrency while remaining single-threaded and cooperative.

A typical entry point is:

```lua
local fibers = require 'fibers'

local function main(scope)
  -- application code here
end

fibers.run(main)
```

Inside `main` you work in terms of scopes, operations, and ordinary Lua functions. The runtime, poller, and backends handle scheduling and clean-up.

---

## Highlights

### Fail-fast supervision scopes

Every fiber runs in a scope. If a fiber fails, its scope records the first failure as the *primary* failure, cancels sibling work in that scope, and runs finalisers to unwind resources.

Outcomes are reported at `fibers.run` and `fibers.run_scope` boundaries. In most cases application code can use `error`/`assert` and rely on the scope boundary for reporting.

### First-class operations (“Ops”)

Anything that may block is represented as an `Op`: channel send/receive, sleeps, I/O readiness, stream reads/writes, subprocess completion, scope join, and so on.

Ops can be combined using:

* `choice`, `named_choice`, `boolean_choice`, `race`
* `guard`
* `bracket`
* `:wrap`
* and (for advanced use) `with_nack` / abort behaviour.

### Scope boundaries as operations

A scope boundary can itself be expressed as an `Op` via `fibers.run_scope_op`, so an entire subtree of work can be raced against other events (timeouts, cancellation triggers, I/O) using the same combinators used for channels and timers.

### Integrated I/O and subprocesses

Non-blocking file descriptors are wrapped as buffered `Stream` objects. Readiness integrates with the poller. The exec layer runs subprocesses with configurable stdio, exposes their lifetime as ops, and ensures they are shut down with their owning scope.

---

## Examples

### 1. Fail fast and inspect failures at the boundary

`fibers.run_scope` returns:

* `status` (`"ok"|"failed"|"cancelled"`)
* a `report` snapshot
* either results (on `"ok"`) or the primary error/reason (on not-ok)

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function main()
  -- Start a child task under the main scope.
  fibers.spawn(function()
    sleep.sleep(0.5)
    print("first: finished ok")
  end)

  -- Run work in a nested child scope and observe its outcome.
  local status, report, value_or_primary = fibers.run_scope(function(child)
    child:finally(function()
      print("finaliser 1 (outer)")
    end)

    child:finally(function()
      print("finaliser 2 (inner)")
      -- If the scope is already failed/cancelled, this becomes a secondary error.
      -- If the scope was otherwise ok, this becomes the primary failure.
      error("finaliser 2 failed")
    end)

    sleep.sleep(0.1)
    error("child: boom")
  end)

  print("child scope status:", status, tostring(value_or_primary))

  if report and report.extra_errors and #report.extra_errors > 0 then
    print("secondary errors:")
    for i, e in ipairs(report.extra_errors) do
      print("  [" .. i .. "]", e)
    end
  end
end

fibers.run(main)
```

Inside scopes you can allow errors to escape; the scope records the first failure, cancels siblings, runs finalisers, and reports the outcome at the boundary.

If the top-level `main` fails, `fibers.run(main)` raises the primary failure.

---

### 2. Channels and timeouts using the event algebra

```lua
local fibers = require 'fibers'
local chan   = require 'fibers.channel'
local sleep  = require 'fibers.sleep'

local function main()
  local c = chan.new()

  -- Producer
  fibers.spawn(function()
    sleep.sleep(0.1)
    c:put("hello")
  end)

  local function read_with_timeout()
    local read_op    = c:get_op()
    local timeout_op = sleep.sleep_op(1.0)

    local ev = fibers.named_choice{
      data    = read_op,
      timeout = timeout_op,
    }

    local which, value = fibers.perform(ev)

    if which == "data" then
      return true, value
    else
      return false, "timed out"
    end
  end

  local ok, value_or_err = read_with_timeout()
  print("result:", ok, value_or_err)
end

fibers.run(main)
```

This is the intended timeout pattern: race an op against `sleep.sleep_op(...)` using `choice`/`named_choice`.

---

### 3. Race an entire subtree of work against a timeout

Use `fibers.run_scope_op` to represent a structured subtree as an op. The op resolves when the child scope has joined (including finalisers and attached children).

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function main()
  local function subtree_op()
    return fibers.run_scope_op(function(child)
      -- Launch work under the child scope.
      child:spawn(function()
        sleep.sleep(2.0)
        print("subtree: finished")
      end)

      -- Return values from the boundary function if needed.
      return "started"
    end)
  end

  -- Race the subtree boundary against a 1s timeout.
  local ev = fibers.named_choice{
    subtree = subtree_op(),        -- yields: st, rep, results/primary
    timeout = sleep.sleep_op(1.0), -- yields: nothing
  }

  local which, st, rep, v = fibers.perform(ev)

  if which == "timeout" then
    print("timed out; subtree scope has been cancelled")
    return
  end

  -- which == "subtree"
  if st == "ok" then
    print("subtree boundary ok:", tostring(v))
  else
    print("subtree boundary not ok:", st, tostring(v))
  end

  if rep and rep.extra_errors and #rep.extra_errors > 0 then
    print("subtree secondary errors:", #rep.extra_errors)
  end
end

fibers.run(main)
```

If `subtree_op` loses in an outer `choice`, its child scope is cancelled with reason `"aborted"` and then joined deterministically.

---

### 4. Run a subprocess bound to a scope

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

local function main()
  fibers.run_scope(function()
    local cmd = exec.command{
      "ls", "-l",
      stdout = "pipe",
    }

    -- output_op returns:
    --   out, status, code, signal, err
    local out, status, code, signal, err = fibers.perform(cmd:output_op())

    if status == "exited" and code == 0 then
      print(out)
    else
      print("command failed:", status, code, signal, err)
    end
  end)
end

fibers.run(main)
```

The `Command` is attached to the current scope. On scope exit it is shut down and its streams/handles are cleaned up.

---

## Concepts in brief

### Fibers

A **fiber** is a lightweight task scheduled by the runtime.

* `fibers.run(main)` starts the scheduler and runs `main` inside a scope under the process root.
* `fibers.spawn(fn, ...)` creates new fibers under the current scope and calls `fn(...)` in them.

You do not manually join fibers; scopes track obligations and join deterministically.

### Scopes

A **scope** is a supervision domain with a tree structure and fail-fast semantics.

* Each fiber runs within some scope.
* When a scope fails or is cancelled:

  * admission is closed,
  * attached child scopes are cancelled,
  * in-flight operations observe cancellation via `fibers.perform`,
  * finalisers run in LIFO order during join.

Scope outcomes are reported via boundaries as:

```lua
status, report, ...         -- on ok: ... are results
status, report, primary     -- on not-ok: primary is error/reason
```

The `report` contains:

* `extra_errors`: secondary errors after the primary has been established;
* `children`: joined child outcomes with nested reports.

### Operations (`Op`)

An **operation** represents something that may block.

Ops can be combined with `choice`/`race`/`named_choice` and related combinators. To perform an op:

* use `fibers.perform(op)` inside a fiber (raises on failure/cancellation), or
* use `fibers.try_perform(op)` when you want status-first results.

### I/O and streams

The I/O layer wraps non-blocking file descriptors in buffered `Stream` objects and exposes operations such as:

* `read_line_op`, `read_all_op`, `read_exactly_op`
* `write_string_op`

Because these are ops, they can be raced and cancelled in the same way as channels and timers.

### Subprocesses

The exec layer runs subprocesses under scopes:

* constructs commands and stdio wiring,
* exposes lifecycle as ops (`run_op`, `shutdown_op`, `output_op`, etc.),
* attaches clean-up to scope finalisers so processes are shut down on scope exit.

---

## Error handling

Inside a scope:

* letting an error escape a fiber is a normal way to signal failure;
* the first failure becomes the scope’s primary failure and triggers cancellation of siblings;
* additional failures (including finaliser failures once the scope is already not-ok) are recorded as secondary errors in `report.extra_errors`.

At the boundary:

* `fibers.run(main)` raises the primary failure/reason (or returns on success),
* `fibers.run_scope(fn)` returns `status, report, ...` as described above.

Because failures are handled at boundaries, `pcall` is usually only needed where you intend local recovery.

---

## Requirements and installation

### Lua and platform

* Lua 5.1–5.5 or LuaJIT.
* A POSIX-like platform (currently developed and tested on Linux).

### Backend support

`fibers` uses a pluggable backend for polling and subprocess handling. You need at least one compatible stack available.

* **FFI backend (preferred)**

  * LuaJIT, or PUC Lua with cffi-lua
  * Uses `epoll` for I/O and `pidfd` for process completion.

* **luaposix backend**

  * `luaposix`
  * Uses `poll`/`select` plus `SIGCHLD` for process completion.

* **nixio backend**

  * `nixio`
  * Uses a double-fork scheme for process completion and `poll` for I/O.

OS-specific code is isolated in backends (`fibers.io.*_backend` and the poller), so adding support for other platforms is mostly a matter of implementing a compatible backend.

### Installation

Add the repository to your `package.path` (and `package.cpath` if necessary) so that modules such as `fibers`, `fibers.channel`, `fibers.sleep`, `fibers.io.file`, and `fibers.exec` can be `require`d.

Once available, the typical entry point is:

```lua
local fibers = require 'fibers'

local function main(scope)
  -- application code here
end

fibers.run(main)
```

From that point on, application code is structured in terms of scopes, operations, and ordinary Lua functions. The runtime ensures that blocking work is expressed as ops, long-lived work is owned by scopes, and everything is shut down cleanly.

---

## Acknowledgements

The design of *fibers* owes a substantial debt to Andy Wingo’s work on lightweight concurrency and Concurrent ML in Lua. In particular, the library was shaped by his article [“lightweight concurrency in lua”](https://wingolog.org/archives/2018/05/16/lightweight-concurrency-in-lua) and by the original [`fibers`](https://github.com/snabbco/snabb/tree/master/src/lib/fibers) and [stream](https://github.com/snabbco/snabb/tree/master/src/lib/stream) implementations in Snabb’s codebase, which provided both the conceptual model and many of the practical patterns used here. Many good ideas you may find in *fibers* are quite likely to have appeared there first!
