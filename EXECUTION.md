# Process execution (`fibers.exec`)

This document describes how to start and manage external processes using this library.

It focuses on usage from the top-level `fibers.lua` entry points:

- `fibers.run` – initialises the scheduler and root scope.
- `fibers.spawn(fn, ...)` – starts a new fiber in the *current* scope.

The process execution API itself is provided by `fibers.exec`.

Typical imports:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'
````

---

## Overview

The execution subsystem provides:

* A `Command` abstraction for a single external process.
* Structured lifetime management: each `Command` is owned by the scope in which it is created.
* Configurable stdin/stdout/stderr:

  * inherit from the parent process
  * connect to `/dev/null`
  * pipe via `Stream`
  * reuse another stream (including `stdout` for `stderr`)
* Operations (`Op`s) for:

  * waiting for process completion
  * graceful shutdown with a timeout and forced kill
  * capturing stdout (and optionally stderr) as a string

The underlying implementation uses platform-specific backends:

* Linux `pidfd` when available.
* A portable `SIGCHLD` + self-pipe backend otherwise.

These details are hidden behind the `fibers.exec` interface.

---

## Basic usage from `fibers.run`

`exec.command` must be called from inside a fiber. In practice this means inside the function passed to `fibers.run` or a fiber spawned from it.

Typical pattern:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  -- Build a command: argv[1] is the programme, argv[2..n] are arguments.
  local cmd = exec.command("ls", "-1")

  -- Capture stdout as a string and wait for the process to exit.
  local out, status, code_or_sig, err =
    scope:perform(cmd:output_op())

  if status == "ok" or (status == "exited" and code_or_sig == 0) then
    print("ls output:\n" .. out)
  else
    print("ls failed:", status, code_or_sig, err)
  end
end)
```

Key points:

* Use `fibers.run(function(scope) ... end)` as the entry point.
* Use `scope:perform(op)` to run `Op`s (including the ones returned by `Command` methods) in a way that respects scope cancellation and fail-fast semantics.
* The command’s lifetime is bound to `scope`: when `scope` finishes, the process will be shut down and its resources cleaned up.

---

## Constructing commands

The main entry point is:

```lua
local exec = require 'fibers.exec'

-- Table form
local cmd = exec.command{
  "sh", "-c", "echo hello",
  cwd = "/tmp",
  env = { FOO = "bar" },
  stdin  = "null",
  stdout = "pipe",
  stderr = "stdout",
  shutdown_grace = 2.0,
}

-- Positional form (argv only, default options)
local cmd2 = exec.command("ls", "-l", "/")
```

Both forms create a `Command` object. In table form the fields are:

* `spec[1]`, `spec[2]`, … – argv elements
* `cwd` – working directory (string or `nil`)
* `env` – table of environment variables (`string -> string|nil`)
* `flags` – table; currently used for options such as `setsid`
* `stdin`, `stdout`, `stderr` – stdio configuration (see below)
* `shutdown_grace` – timeout in seconds for graceful shutdown, default `1.0`

There is also a set of setter methods which can be used before the command is started:

```lua
cmd:set_cwd("/var/log")
   :set_env{ LANG = "C" }
   :set_stdin("null")
   :set_stdout("pipe")
   :set_stderr("stdout")
   :set_shutdown_grace(5.0)
```

All setters return `self` and will raise if the command has already been started.

---

## Stdio configuration

Each of `stdin`, `stdout`, `stderr` can be configured using either:

* a string mode; or
* an existing `Stream` instance.

Allowed string modes:

* `"inherit"` – use the parent process’s file descriptor (default).
* `"null"` – connect to `/dev/null` (read-only or write-only as appropriate).
* `"pipe"` – create a new pipe connected to the parent.
* `"stdout"` – for `stderr` only; share the same destination as `stdout`.

Passing a `Stream` instance (from `fibers.io.stream` or `fibers.io.file`) uses the underlying file descriptor for that stream. In this case the `Command` does not own the stream; it will not be closed automatically.

Example configurations:

```lua
local file = require 'fibers.io.file'

-- Discard all output, no input
local cmd1 = exec.command{
  "my-tool",
  stdin  = "null",
  stdout = "null",
  stderr = "null",
}

-- Pipe stdout to a stream, inherit stderr
local out_file = assert(file.open("out.log", "w"))
local cmd2 = exec.command{
  "my-tool",
  stdout = out_file,     -- user-supplied stream
}

-- Capture stdout and stderr together
local cmd3 = exec.command{
  "my-tool",
  stdout = "pipe",
  stderr = "stdout",     -- merged with stdout
}
```

If you set `stdout = "pipe"` or `stderr = "pipe"`, the backend will create `Stream`s for you, and the `Command` will own and close them during cleanup.

---

## Inspecting command state

The main introspection methods are:

```lua
local status, code_or_sig, err = cmd:status()
local pid                     = cmd:pid()
local argv_copy               = cmd:argv()
```

The status is one of:

* `"pending"` – created but not yet started.
* `"running"` – process has been started and is still running.
* `"exited"` – process exited normally.
* `"signalled"` – process terminated due to a signal.
* `"failed"` – failure to start or manage the process (for example `exec` error).

For `"exited"` and `"signalled"` the second result is:

* exit code (integer) for `"exited"`;
* signal number (integer) for `"signalled"`.

For `"failed"` the second result is `nil` and the third result is an error string.

Note that the process is only started when you first use one of the operations below (`run_op`, `shutdown_op`, `output_op`, and so on), or when you explicitly request a piped stream.

---

## Accessing stdio streams

You can obtain `Stream`s for the child’s stdio via:

```lua
local stdin_stream,  serr1 = cmd:stdin_stream()
local stdout_stream, serr2 = cmd:stdout_stream()
local stderr_stream, serr3 = cmd:stderr_stream()
```

Behaviour:

* If the mode is `"inherit"` or `"null"`, these functions return `nil`.
* If the mode is `"stream"`, you get back the user-supplied stream.
* If the mode is `"pipe"`, the process is started if necessary and you get a new `Stream` instance on the parent side.
* For `stderr_stream`, if mode is `"stdout"`, it delegates to `stdout_stream`.

Example: streaming a child’s output line by line while it runs:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  local cmd = exec.command{
    "ping", "-n", "5", "example.org",
    stdout = "pipe",
    stderr = "stdout",
  }

  local out_stream, err = cmd:stdout_stream()
  assert(out_stream, err)

  -- Stream output in a child scope of the main scope.
  scope:spawn(function(child_scope)
    while true do
      local line, lerr = child_scope:perform(out_stream:read_line_op())
      if not line then
        break
      end
      print("[child]", line)
    end
  end)

  local status, code_or_sig, cerr =
    scope:perform(cmd:run_op())

  print("child finished:", status, code_or_sig, cerr)
end)
```

---

## Waiting for completion

To wait for a process to finish, use `run_op`:

```lua
local status, code, signal, err =
  scope:perform(cmd:run_op())
```

Semantics:

* If the process has not yet been started, `run_op` will start it.
* If the process is already complete, `run_op` resolves immediately.
* The results are:

  * `status` – `"exited"`, `"signalled"` or `"failed"`.
  * `code` – exit code (for `"exited"`) or `nil`.
  * `signal` – signal number (for `"signalled"`) or `nil`.
  * `err` – error string for `"failed"`, or `nil` otherwise.

Because `run_op` is an `Op`, it participates in `choice` and respects scope cancellation when used with `scope:perform`.

---

## Graceful shutdown

To request a graceful shutdown, use `shutdown_op`:

```lua
-- Optional override of the grace period (seconds)
local status, code, signal, err =
  scope:perform(cmd:shutdown_op(5.0))
```

Behaviour:

1. Ensure the process has been started.
2. Send a polite termination request:

   * `terminate()` if the backend implements it; or
   * a default signal via `send_signal()` (commonly `SIGTERM`).
3. Race:

   * `cmd:run_op()` (process exits), and
   * a timer (`sleep_op(grace)`).
4. If the process exits within the grace period, return that status.
5. If not, attempt a more forceful kill:

   * `kill()` if provided; otherwise fall back to `send_signal()` again.
6. Wait for the process to complete, then return the final status.

`shutdown_op` is suitable to call during normal control flow (for example when you decide to stop a worker) and is also used automatically when the owning scope exits (see below).

---

## Capturing output

### `output_op` – stdout only

`output_op` runs the process to completion while capturing all data from stdout into a single string:

```lua
local out, status, code, signal, err =
  scope:perform(cmd:output_op())
```

Semantics:

* If `stdout` would otherwise be inherited, `output_op` arranges for it to be a pipe instead.
* The process is started if necessary.
* All data from the stdout stream is read using `read_all_op`.
* Once reading completes, the operation waits for the process to exit.
* It returns:

  * `out` – captured stdout as a string (possibly empty).
  * `status`, `code`, `signal`, `err` – as for `run_op`.

Standard usage pattern:

```lua
local cmd = exec.command("sh", "-c", "echo hello; exit 0")
local out, status, code, signal, err =
  scope:perform(cmd:output_op())

if status == "exited" and code == 0 then
  print("child said:", out)
else
  print("child failed:", status, code or signal, err)
end
```

### `combined_output_op` – stdout and stderr together

If you want stdout and stderr merged, use `combined_output_op`:

```lua
local out, status, code, signal, err =
  scope:perform(cmd:combined_output_op())
```

Preconditions:

* `stderr` must not already be configured as `"pipe"` or a direct `Stream`:

  * `combined_output_op` sets `stderr` to `"stdout"` if it was `"inherit"`.

The behaviour is otherwise the same as `output_op`, but with stderr directed to stdout before capture.

---

## Sending signals directly

If you want to send a signal yourself, use `kill`:

```lua
local ok, err  = cmd:kill()        -- default signal (backend-chosen)
local ok2, err2 = cmd:kill("TERM") -- if the backend supports named signals
```

High-level behaviour:

* If the command has not started, `kill` fails with an error.
* If the command has already completed, `kill` returns success.
* Otherwise it forwards the request to the backend, using:

  * an explicit `send_signal(sig)` if passed; or
  * a forceful `kill()` method if available; or
  * `terminate()`; or
  * a default `send_signal()`.

Signal naming and exact behaviour are backend dependent; backends typically accept:

* a numeric signal; and/or
* a symbolic identifier such as `"TERM"`.

---

## Scope-bound lifetime

Each `Command` is created with reference to the current scope:

* `exec.command` asserts that it is called from inside a fiber.
* The `Scope` returned by `Scope.current()` at that point is recorded.
* A `finally` handler is registered on that scope which:

  * performs a best-effort shutdown of the process; and
  * closes any streams owned by the command; and
  * closes the backend handle.

This has two important consequences:

1. If the scope finishes normally or fails, processes started from it are not left running unintentionally.
2. Cleanup runs even when the scope is already in a terminal state; `perform_with_scope_or_raw` uses raw `op.perform_raw` when scope-based cancellation is no longer applicable, so shutdown can complete.

In general:

* create commands in the scope that *owns* their lifetime;
* use `scope:perform(cmd:run_op())`, `scope:perform(cmd:shutdown_op())`, and so on;
* avoid keeping `Command` instances beyond the lifetime of their owning scope.

---

## Summary of typical patterns

### Fire-and-wait with captured output

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  local cmd = exec.command("uname", "-a")
  local out, status, code, signal, err =
    scope:perform(cmd:output_op())

  if status == "exited" and code == 0 then
    print(out)
  else
    print("uname failed:", status, code or signal, err)
  end
end)
```

### Long-lived worker terminated with the scope

Here we run a long-lived process in its own child scope using `scope.run`. The updated `scope.run` returns:

```lua
status, err, extra_errors, ...body_results
```

In many cases only `status` and `err` are required.

```lua
local fibers    = require 'fibers'
local exec      = require 'fibers.exec'
local scope_mod = require 'fibers.scope'

fibers.run(function(scope)
  local cmd = exec.command{
    "some-daemon", "--foreground",
    stdout = "inherit",
    stderr = "inherit",
  }

  -- Run worker in a child scope for clearer lifetime boundaries.
  local status, err, extra_errors, child_status, code, sig, cerr =
    scope_mod.run(function(child_scope)
      -- Wait until the worker dies or the child scope is cancelled.
      return child_scope:perform(cmd:run_op())
    end)

  print("worker scope finished:", status, err)

  -- Optional: record any errors from finaliser cleanup in the worker scope.
  for i, derr in ipairs(extra_errors) do
    print("worker extra failure[" .. i .. "]:", derr)
  end

  -- child_status/code/sig/cerr are the results from cmd:run_op(), if needed.
end)
```

Here, even if the outer `scope` fails due to some other fiber error, the `Command`’s finaliser will shut down the process and release its resources.

---

This concludes the overview of process execution in this library. All interactions with external processes are expressed as `Op`s, and their lifetimes are governed by the same structured concurrency rules as fibers and other resources.
