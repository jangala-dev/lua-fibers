# fibers

`fibers` runs lots of concurrent work in one Lua process, using cooperative fibers and an event loop. The aim is not “threads in Lua”, but something closer to:

* **structured lifetimes** (supervision scopes),
* **first-class blocking operations** (Ops),
* **I/O and subprocesses that behave like Ops**,
* **errors as control flow** (throw freely; catch rarely).

A typical entry point:

```lua
local fibers = require "fibers"

local function main(scope)
  -- application code here
end

fibers.run(main)
```

Inside `main`, you write ordinary Lua. When you need to wait for something, you perform an op. When you need concurrency, you spawn. When you need cleanup, you register a finaliser. Scopes do the rest.

---

## The mental model

### 1) Scopes own time

Every fiber runs “inside” a scope. A scope is the unit of:

* what work is allowed to start,
* what gets cancelled when something goes wrong,
* what must be joined before the scope is considered finished,
* and where cleanup belongs.

If you start work in a scope, that scope is responsible for joining it and running cleanup, even if things fail.

### 2) Waiting is explicit

Anything that might block is an **Op**. Examples:

* `sleep.sleep_op(dt)`
* channel `get_op` / `put_op`
* stream reads/writes (`read_line_op`, `write_string_op`, …)
* socket accept/connect ops
* waiting for a subprocess
* joining a scope

Ops compose. If you can race a channel receive against a timeout, you can do the same with I/O, process completion, or a scope boundary.

### 3) Errors are normal (and scoped)

Inside a scope, it is normal to use `error`, `assert`, or let exceptions escape. The scope boundary is what turns “chaos” into a reportable outcome.

You rarely need `pcall`. When you do catch, it should be because you have a real local recovery plan.

---

## Highlights

## Fail-fast scopes

Within a scope:

* the **first non-cancellation failure** becomes the **primary failure**,
* siblings are cancelled (fail-fast),
* cleanup runs (finalisers),
* later faults become **secondary errors** collected in the report.

At boundaries you get structured outcomes. In most application code, you just throw and move on.

## Ops: a small algebra for waiting

Ops can complete immediately, or they can suspend and resume later. You can combine them using:

* `choice`, `named_choice`, `boolean_choice`, `race`
* `guard`
* `bracket` / `:finally` / `:wrap`
* (advanced) `with_nack` and abort behaviour

Timeouts are not special-cased. They’re just “race X against sleep”.

## I/O and subprocesses participate fully

Streams, sockets, pollers, and subprocesses are built to “feel like ops”:

* blocking reads/writes are ops,
* readiness is registered with the poller and unregistered on abort,
* subprocess lifetime is attached to a scope and shut down on scope exit,
* and you can race them against timeouts like anything else.

---

## Examples

## 1) Fail fast, and inspect the outcome at a boundary

`fibers.run_scope` returns:

* `status` (`"ok"|"failed"|"cancelled"`)
* a `report` snapshot
* either results (on `"ok"`) or the primary error/reason (on not-ok)

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

local function main()
  fibers.spawn(function()
    sleep.sleep(0.5)
    print("sibling: finished ok")
  end)

  local status, report, value_or_primary = fibers.run_scope(function(child)
    child:finally(function()
      print("finaliser 1")
    end)

    child:finally(function()
      print("finaliser 2 (oops)")
      error("finaliser 2 failed")
    end)

    sleep.sleep(0.1)
    error("child: boom")
  end)

  print("child scope:", status, tostring(value_or_primary))

  if report and report.extra_errors and #report.extra_errors > 0 then
    print("secondary errors:")
    for i, e in ipairs(report.extra_errors) do
      print(("  [%d] %s"):format(i, tostring(e)))
    end
  end
end

fibers.run(main)
```

Inside scopes, errors can escape. The scope records the failure, cancels siblings, runs finalisers, and reports the outcome at the boundary.

If the top-level `main` fails, `fibers.run(main)` raises the primary failure.

---

## 2) Channels and timeouts: the intended pattern

```lua
local fibers = require "fibers"
local chan   = require "fibers.channel"
local sleep  = require "fibers.sleep"

local function main()
  local c = chan.new()

  fibers.spawn(function()
    sleep.sleep(0.1)
    c:put("hello")
  end)

  local ev = fibers.named_choice{
    data    = c:get_op(),
    timeout = sleep.sleep_op(1.0),
  }

  local which, value = fibers.perform(ev)

  if which == "data" then
    print("got:", value)
  else
    print("timed out")
  end
end

fibers.run(main)
```

Timeouts are deliberately expressed as “race an op against `sleep_op`”.

---

## 3) Race an entire subtree of work against a timeout

A scope boundary can itself be an op: `fibers.run_scope_op`. It resolves when the child scope has joined (including its finalisers and attached children).

```lua
local fibers = require "fibers"
local sleep  = require "fibers.sleep"

local function main()
  local subtree = fibers.run_scope_op(function(child)
    child:spawn(function()
      sleep.sleep(2.0)
      print("subtree: finished")
    end)
    return "started"
  end)

  local ev = fibers.named_choice{
    subtree  = subtree,            -- yields: st, rep, results/primary
    timeout  = sleep.sleep_op(1.0),
  }

  local which, st, rep, v = fibers.perform(ev)

  if which == "timeout" then
    print("timed out; subtree was cancelled")
    return
  end

  if st == "ok" then
    print("subtree ok:", tostring(v))
  else
    print("subtree not ok:", st, tostring(v))
  end

  if rep and rep.extra_errors and #rep.extra_errors > 0 then
    print("secondary errors:", #rep.extra_errors)
  end
end

fibers.run(main)
```

If `run_scope_op(...)` loses in an outer `choice`, the child scope is cancelled (reason `"aborted"`) and then joined deterministically.

---

## 4) Subprocesses are scope-owned

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"

local function main()
  local status, report, out_or_primary = fibers.run_scope(function()
    local cmd = exec.command{
      "ls", "-l",
      stdout = "pipe",
    }

    local out, st, code, sig, err = fibers.perform(cmd:output_op())

    if st == "exited" and code == 0 then
      return out
    end

    error(("command failed: %s code=%s sig=%s err=%s"):format(
      tostring(st), tostring(code), tostring(sig), tostring(err)
    ))
  end)

  if status == "ok" then
    print(out_or_primary)
  else
    print("scope failed:", status, tostring(out_or_primary))
  end
end

fibers.run(main)
```

Commands are attached to the current scope. On scope exit, they are shut down and their owned streams/handles are cleaned up.

---

## Concepts in brief

## Fibers

A **fiber** is a lightweight task scheduled by the runtime.

* `fibers.run(main)` starts the scheduler and runs `main` inside a scope under the process root.
* `fibers.spawn(fn, ...)` creates a new fiber under the current scope and calls `fn(...)`.

You do not manually join fibers. Scopes track obligations and join deterministically.

## Scopes

A **scope** is a supervision domain with a tree structure and fail-fast semantics.

When a scope fails or is cancelled:

* admission closes (new work is rejected),
* attached child scopes are cancelled,
* in-flight ops observe cancellation via `fibers.perform`,
* finalisers run in LIFO order during join.

Scope outcomes at boundaries:

```lua
status, report, ...         -- on ok: ... are results
status, report, primary     -- on not-ok: primary is error/reason
```

The `report` contains:

* `extra_errors`: faults after the primary is established,
* `children`: joined child outcomes with nested reports.

## Operations (Ops)

An **Op** represents “something that may block”, they are a close translation of `events` in Concurrent ML.

* Perform an op with `fibers.perform(op)` (must be called inside a fiber).
* If the current scope is cancelled or failed, `perform` raises (cancellation uses a sentinel internally).

Because everything that blocks is an op, you can write one set of patterns and reuse them everywhere:

* timeouts (`choice` against `sleep_op`)
* “first ready wins” (`race`, `named_choice`)
* resource safety (`bracket`, `:finally`)
* cancellation-safe cleanups (finalisers, abort handlers)

If you want status-first handling, use an explicit boundary (`run_scope`, `run_scope_op`) or work directly with scope APIs.

## I/O and streams

The I/O layer wraps non-blocking file descriptors as buffered `Stream` objects and exposes ops such as:

* `read_line_op`, `read_all_op`, `read_exactly_op`
* `write_string_op`

These ops integrate with the poller and can be raced, timed out, and cancelled like anything else.

A particularly useful helper is `stream.merge_lines_op`, which races a line read across multiple named streams:

```lua
local name, line, err = fibers.perform(stream.merge_lines_op({ a = s1, b = s2 }))
```

## Subprocesses

The exec layer runs subprocesses under scopes:

* commands and stdio wiring are configured up-front,
* lifecycle is exposed as ops (`run_op`, `shutdown_op`, `output_op`, …),
* cleanup is attached to scope finalisers so processes are shut down on scope exit.

---

## Error handling

Inside a scope:

* letting an error escape a fiber is normal;
* the first failure becomes the primary failure and triggers cancellation of siblings;
* additional failures (including finaliser failures once not-ok) become secondary errors in `report.extra_errors`.

At boundaries:

* `fibers.run(main)` returns results on success, otherwise raises the primary failure/reason (as a string/number),
* `fibers.run_scope(fn)` returns `status, report, ...` as described above.

Rule of thumb:

* **Throw freely** inside a scope.
* **Catch rarely**, only when you genuinely want local recovery.
* **Always register cleanup** with `finally`/`bracket`/scope finalisers rather than trying to “survive” cancellation.

---

## Requirements and installation

### Lua and platform

* Lua 5.1–5.5 or LuaJIT.
* A POSIX-like platform (currently developed and tested on Linux).

### Backend support

`fibers` uses pluggable backends for polling and subprocess handling. You need at least one compatible stack:

* **FFI backend (preferred)**

  * LuaJIT (or PUC Lua with cffi-lua)
  * `epoll` for I/O; `pidfd` for process completion (when available)

* **luaposix backend**

  * `luaposix`
  * `poll`/`select` plus `SIGCHLD` for process completion

* **nixio backend**

  * `nixio`
  * `poll` for I/O; a double-fork scheme for evented process completion

OS-specific code is isolated in `fibers.io.*_backend` and poller backends, so adding a platform is “implement the backend contract”, not “rewrite the library”.

### Installation

Add the repository to your `package.path` (and `package.cpath` if needed) so modules such as `fibers`, `fibers.channel`, `fibers.sleep`, `fibers.io.file`, `fibers.io.stream`, and `fibers.io.exec` can be `require`d.

---

## Acknowledgements

The design owes a substantial debt to Andy Wingo’s writing on concurrency, including his article [_lightweight concurrency in lua_](https://wingolog.org/archives/2018/05/16/lightweight-concurrency-in-lua) and his Snabb [`fibers`](https://github.com/snabbco/snabb/tree/master/src/lib/fibers) and [`stream`](https://github.com/snabbco/snabb/tree/master/src/lib/stream) implementations. And of course to John Reppy's original CML!
