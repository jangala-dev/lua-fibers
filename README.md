# fibers

`fibers` is a small library for running many concurrent tasks in one Lua process, with:

- structured lifetimes (supervision scopes),
- cancellable operations (the “event algebra”),
- integrated I/O and subprocess handling.

It is aimed at Lua programmers who want to write robust, highly concurrent services and tools while staying in a single-threaded, easy-to-reason-about model.

The main pattern is:

```lua
local fibers = require 'fibers'

local function main(scope)
  -- normal code here
end

fibers.run(main)
```

Inside `main` you work in terms of scopes, operations and ordinary Lua functions. The runtime, poller and backends handle scheduling and clean-up.

---

## Highlights

* **Fail-fast supervision scopes**

  Every fiber runs in a scope. If a child fails, its scope records the error, cancels siblings and runs finalisers to unwind resources. Failures are reported at `fibers.run` / `fibers.run_scope` boundaries; most application code can simply `error` or `assert` and let the scope handle it.

* **First-class operations (“Ops”)**

  Anything that may block is represented as an `Op`: channel sends/receives, sleeps, I/O readiness, subprocess exit, scope completion, and so on. Ops can be combined with `choice`, `named_choice`, `boolean_choice`, `guard`, `bracket`, and `wrap`. Lean in to the algebra: it is highly composable and can often replace explicit helper fibers.

* **Scopes as operations**

  Scopes themselves can be expressed as operations, so entire trees of work can be raced against other events (timeouts, cancellation triggers, I/O) using the same algebra as for channels and timers.

* **Integrated I/O and subprocesses**

  Non-blocking file descriptors are wrapped as buffered `Stream` objects. Readiness integrates with the poller. The exec layer runs subprocesses with configurable stdio, exposes their lifetime as ops, and ensures they are shut down with their owning scope.

---

## Examples

### 1. Fail fast and inspect failures at the boundary

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function main()
  -- Start a child task under the main scope.
  fibers.spawn(function()
    sleep.sleep(0.5)
    print("first: finished ok")
  end)

  -- Run some work in a nested child scope and observe its outcome.
  local status, err, extra_errors = fibers.run_scope(function(child)
    child:finally(function()
      print("finaliser 1 (outer)")
    end)

    child:finally(function()
      print("finaliser 2 (inner)")
      -- This error is recorded as an additional failure.
      error("finaliser 2 failed")
    end)

    -- Child begins its work and fails
    sleep.sleep(0.1)
    error("child: boom")
  end)

  print("child scope status:", status, err)
  if #extra_errors > 0 then
    print("child scope finaliser failures:")
    for i, e in ipairs(extra_errors) do
      print("  [" .. i .. "]", e)
    end
  end

  -- No need for extra blocking; run_scope already joins its child scope.
end

fibers.run(main)
```

Inside scopes you can freely `error` or `assert`. Uncaught failures:

* are recorded by the scope,
* cancel sibling work,
* run finalisers for clean-up,
* and are reported at `fibers.run` / `fibers.run_scope`.

There is usually no need for `pcall` in normal concurrent code; you inspect failures at the boundaries instead of catching them everywhere.

If the top-level `main` fails, `fibers.run(main)` re-raises the primary failure.

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

    -- One Op representing “either read or timeout”.
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

Here:

* the channel receive and the timer are both first-class operations,
* they participate in `named_choice`,
* they observe scope cancellation automatically, and
* they can be combined in the same way as other primitives.

You do not need a special `with_timeout()` helper; racing an operation against `sleep.sleep_op` is the intended pattern.

---

### 3. Race an entire subtree of work against a timeout

Scopes themselves can be expressed as operations using `fibers.scope_op`. That allows whole trees of work to be raced as a single unit.

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local function main()
  -- Build an Op that runs a child scope and completes when that scope does.
  local function subtree_op()
    return fibers.scope_op(function(child)
      -- Launch some work under the child scope.
      child:spawn(function()
        sleep.sleep(2.0)
        print("subtree: finished")
      end)

      -- Represent the whole subtree as an Op:
      -- this Op becomes ready when the child scope reaches a terminal state.
      return child:join_op()
    end)
  end

  -- Race the subtree against a 1s timeout.
  local ev = fibers.boolean_choice(
    subtree_op(),           -- true branch: subtree finishes (ok/failed/cancelled)
    sleep.sleep_op(1.0)     -- false branch: timeout
  )

  local subtree_won, status = fibers.perform(ev)

  if subtree_won then
    print("subtree completed with status:", status)
  else
    print("timed out; subtree scope has been cancelled")
  end
end

fibers.run(main)
```

Because scopes are composable as ops:

* you can express “do this whole batch of work, but only until X” in the same algebra you use for channels and timers;
* losing branches are cancelled and cleaned up via scope finalisers.

---

### 4. Run a subprocess bound to a scope

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

local function main()
  fibers.run_scope(function()
    local cmd = exec.command{
      "ls", "-l",
      stdout = "pipe",  -- capture stdout
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

The `Command` is attached to the current scope. On scope exit:

* it is given a grace period to shut down politely,
* then killed if still running,
* and any owned streams and backend handles are closed.

From user code, process operations are just more ops: they can be raced against timeouts, scope cancellation, or other events using the same tools as channels and timers.

---

## Concepts in brief

### Fibers

A **fiber** is a lightweight task scheduled by the runtime.

* `fibers.run(main)` starts the scheduler and a root supervision scope, runs `main` inside a fiber, and returns only when the root scope has finished and cleaned up.
* `fibers.spawn(fn, ...)` creates new fibers under the current scope and calls `fn(...)` in them.

Once you are inside `fibers.run`, there are no “coloured” functions beyond the requirement that blocking ops must be performed from inside a fiber. You do not manually join fibers; scopes track them and clean them up.

### Scopes

A **scope** is a supervision domain with a tree structure and fail-fast semantics.

* Each fiber runs within some scope.
* When a scope fails or is cancelled:

  * child scopes are cancelled,
  * child fibers stop as their ops observe cancellation,
  * finalisers registered with `scope:finally` run in LIFO order to clean up resources.
* Scopes record:

  * a status (`"running"`, `"ok"`, `"failed"`, `"cancelled"`),
  * a primary error or cancellation reason,
  * any additional finaliser-time failures.

Scopes can be:

* observed from outside via `fibers.run_scope` or `scope:join_op()` / `scope:done_op()`, and
* wrapped as operations via `fibers.scope_op`, so that entire subtrees of work can participate in `choice`.

Inside a scope, normal code typically does not wait for the scope itself; it registers finalisers and lets the parent scope observe status.

### Operations (`Op`)

An **operation** (`Op`) represents something that may block:

* channel sends and receives,
* sleeps and timeouts,
* I/O readiness and stream reads/writes,
* subprocess completion,
* scope completion or cancellation,
* and any other primitive you build in the same style.

Ops are not tied to a particular fiber until they are performed. They can be:

* combined with `fibers.choice`, `fibers.named_choice`, `fibers.boolean_choice`, and `fibers.race`,
* delayed with `fibers.guard`,
* bracketed with acquire/release logic via `fibers.bracket`,
* post-processed via `:wrap`,
* given abort behaviour using negative acknowledgements (`with_nack` / `on_abort`).

To perform an operation:

* use `fibers.perform(op)` inside a fiber, which:

  * honours the current scope’s cancellation rules,
  * treats scope failure as an error,
  * and otherwise returns the operation’s results.

Where you genuinely need non-cancellable behaviour (for example, in some finalisers), lower-level functions are available (`perform_raw`), but most application code should use `fibers.perform`.

### I/O and streams

The **I/O layer** wraps non-blocking file descriptors in buffered `Stream` objects:

* integrates readability/writability with the poller (epoll, or poll/select),
* exposes operations such as:

  * `read_line_op`, `read_all_op`, `read_exactly_op`,
  * `write_string_op`, and their synchronous wrappers,
* supports files, pipes, UNIX sockets and other backends through adaptor modules.

Since `Stream` operations are ops, they can be raced and cancelled like any other blocking activity.

### Subprocesses

The **exec layer** runs subprocesses under scopes:

* builds a `Command` from an argv vector and stdio configuration,
* starts the process lazily when you first use it,
* exposes its lifetime as ops:

  * `run_op` – wait for exit,
  * `shutdown_op` – attempt graceful shutdown with a grace period then force kill,
  * `output_op` – capture stdout (and optionally stderr) and wait for exit,
* attaches process clean-up to scope finalisers, so that processes are always shut down when their owning scope ends.

Again, callers mostly see these as just another family of ops.

---

## Error handling

Inside a scope:

* letting an error escape a fiber is the normal way to signal failure;
* the scope tracks the first failure as its primary error and cancels siblings;
* finalisers run regardless and may themselves fail, in which case finaliser failures are recorded separately.

At the boundary:

* `fibers.run(main)` re-raises the primary error of the root scope (or returns normally on success),
* `fibers.run_scope(fn)` returns:

  * `status`, `err`, `extra_errors`, and any results returned by `fn`.

Because errors are funnelled through scopes in this way, `pcall` is rarely needed in ordinary concurrent code. You use it only where you truly want local recovery.

---

## Requirements and installation

### Lua and platform

* Lua 5.1–5.5 or LuaJIT.
* A POSIX-like platform (currently developed and tested on Linux).

### Backend support

`fibers` uses a pluggable backend for polling and subprocess handling. You need at least one of the following stacks available:

* **FFI backend (preferred)**
  * LuaJIT, or PUC Lua with [cffi-lua](https://github.com/q66/cffi-lua)
  * Uses `epoll` for I/O and `pidfd` for process completion.

* **luaposix backend**
  * `luaposix`
  * Uses `poll`/`select` plus `SIGCHLD` for process completion.

* **nixio backend**
  * `nixio`
  * Uses a double-fork scheme for process completion and `poll` for I/O.

The library will prefer an FFI-based backend when available, and otherwise fall back to a `luaposix`-based or `nixio`-based backend.

OS-specific code is isolated in these backends (`fibers.io.*_backend` and the poller), so adding support for other platforms (eg. FreeBSD, macOS, Windows) should be largely a matter of implementing a compatible backend.

### Installation

Add the repository to your `package.path` (and `package.cpath` if necessary) so that modules such as `fibers`, `fibers.channel`, `fibers.sleep`, `fibers.io.file` and `fibers.exec` can be `require`d.

Once available, the typical entry point is:

```lua
local fibers = require 'fibers'

local function main()
  -- application code here
end

fibers.run(main)
```

From that point on, application code is structured in terms of scopes, operations and normal Lua functions. The runtime ensures that blocking work is expressed as ops, long-lived work is owned by scopes, and everything is shut down cleanly.

---

## Acknowledgements

The design of *fibers* owes a substantial debt to Andy Wingo’s work on lightweight concurrency and Concurrent ML in Lua. In particular, the library was shaped by his article [“lightweight concurrency in lua”](https://wingolog.org/archives/2018/05/16/lightweight-concurrency-in-lua) and by the original [`fibers`](https://github.com/snabbco/snabb/tree/master/src/lib/fibers) and [stream](https://github.com/snabbco/snabb/tree/master/src/lib/stream) implementations in Snabb’s codebase, which provided both the conceptual model and many of the practical patterns used here. Any good ideas you find in *fibers* are quite likely to have appeared there first!
