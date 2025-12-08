# fibers

`fibers` is a small library for running many concurrent tasks in one Lua process, with structured lifetimes, cancellable operations, and integrated I/O and subprocess handling.

It is aimed at “do a lot of things at once, shut them down cleanly, and know what failed”.

---

## Examples

### Run several tasks and fail fast on error

```lua
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function(scope)
  -- Start two child tasks under the main scope.
  fibers.spawn(function(s)
    sleep.sleep(0.5)
    print("first: finished ok")
  end)

  fibers.spawn(function(s)
    sleep.sleep(0.2)
    error("second: something went wrong")
  end)

  -- Block until the main scope’s child scope has finished.
  local status, err = fibers.run_scope(function(child)
    -- Do more work here if you like.
  end)

  print("main scope status:", status, err)
end)
```

If any child fails, its scope records the error, cancels its siblings and runs defers to clean up resources. The top-level `fibers.run` then re-raises the primary failure.

---

### Use channels and timeouts with the event algebra

```lua
local fibers = require 'fibers'
local chan   = require 'fibers.channel'
local sleep  = require 'fibers.sleep'

fibers.run(function(scope)
  local c = chan.new()

  -- Producer
  fibers.spawn(function(s)
    sleep.sleep(0.1)
    c:put("hello")
  end)

  -- Consumer with timeout: either get a value, or time out after 1s.
  local function read_with_timeout()
    local read_op    = c:get_op()
    local timeout_op = sleep.sleep_op(1.0)

    -- Race the two operations.
    local which, value = fibers.named_choice{
      data    = read_op,
      timeout = timeout_op,
    }

    if which == "data" then
      return true, value
    else
      return false, "timed out"
    end
  end

  local ok, value_or_err = read_with_timeout()
  print("result:", ok, value_or_err)
end)
```

Here the channel read and the timer are both first-class operations. They participate in `choice`, support cancellation from their scope, and can be composed in the same way as other primitives.

---

### Run a subprocess bound to a scope

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  local cmd = exec.command{
    "ls", "-l",
    stdout = "pipe",
  }

  local out, status, code, signal, err =
    fibers.perform(cmd:output_op())

  if status == "exited" and code == 0 then
    print(out)
  else
    print("command failed:", status, code, signal, err)
  end
end)
```

The `Command` is attached to the current scope. On scope exit it is given a grace period to shut down, then killed if still running, and any associated streams are closed.

---

## Concepts in brief

A **fiber** is a lightweight task scheduled by the runtime. `fibers.run` starts the scheduler and a root supervision scope; `fibers.spawn` creates more fibers under the current scope.

An **operation (`Op`)** represents something that may block: reading from a channel, waiting for a timeout, waiting for a process to exit, and so on. Operations can be composed with `choice`, guarded, bracketed with acquire/release logic, or wrapped to add behaviour. They are not tied to a particular task until performed.

A **scope** is a supervision domain with a tree structure and fail-fast semantics. Each fiber runs within some scope. When a scope fails or is cancelled, child scopes are cancelled and their work is unwound using registered defers. Scopes expose operations to wait for completion or cancellation, and wrappers to run other operations under their cancellation policy.

The **I/O layer** wraps non-blocking file descriptors in buffered `Stream` objects, integrates readiness with the poller (epoll or poll/select), and provides helpers for files, pipes and UNIX sockets. The **exec layer** builds on this to start subprocesses with configurable stdio, expose their lifetime as an `Op`, and ensure they are shut down with their owning scope.

The intent is that “something might block” is always expressed as an `Op`, and “something might live for a while” is always owned by a scope. The runtime, poller and backends supply the mechanics; application code mostly works in terms of scopes, operations and normal Lua functions.

---

## Requirements and installation

The library targets Lua 5.1–5.4 and LuaJIT on POSIX-like systems. It prefers FFI-based backends (epoll, pidfd) where available, and falls back to luaposix-based poll/select and SIGCHLD backends otherwise.

Add the repository to your `package.path` so that modules such as `fibers`, `fibers.channel`, `fibers.sleep` and `fibers.io.file` can be `require`d.
