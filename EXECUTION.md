# Process execution (`fibers.exec`)

This document describes how to start and manage external processes using this library.

It focuses on usage from the top-level `fibers.lua` entry points:

* `fibers.run(main_fn, ...)` – initialises the scheduler and root scope.
* `fibers.spawn(fn, ...)` – starts a new fiber in the current scope.
* `fibers.perform(op)` – performs an operation under the current scope (raising on scope failure/cancellation).
* `fibers.run_scope(body_fn, ...)` – runs a child scope and returns its outcome as values.
* `fibers.run_scope_op(body_fn, ...)` – represents a child-scope boundary as an `Op`.

The process execution API itself is provided by `fibers.exec`.

Typical imports:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'
```

---

## Overview

The execution subsystem provides:

* A `Command` abstraction for a single external process.
* Structured lifetime management: each `Command` is owned by the scope in which it is created.
* Configurable stdin/stdout/stderr:

  * inherit from the parent process
  * connect to `/dev/null`
  * pipe via `Stream`
  * reuse another stream (including directing `stderr` to `stdout`)
* Operations (`Op`s) for:

  * waiting for process completion
  * graceful shutdown with a timeout and forced kill
  * capturing stdout (and optionally stderr) as a string

The underlying implementation uses platform-specific backends (for example `pidfd` on Linux when available, or a `SIGCHLD`-based fallback). These details are hidden behind the `fibers.exec` interface.

---

## Basic usage from `fibers.run`

`exec.command` must be called from inside a fiber. In practice this means inside the function passed to `fibers.run`, inside a fiber started by `fibers.spawn`, or inside a child scope started by `fibers.run_scope`.

Typical pattern:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  -- Build a command: argv[1] is the programme, argv[2..n] are arguments.
  local cmd = exec.command("ls", "-1")

  -- Capture stdout as a string and wait for the process to exit.
  local out, st, code, sig, err = fibers.perform(cmd:output_op())

  if st == "exited" and code == 0 then
    print("ls output:\n" .. out)
  else
    print("ls failed:", st, code, sig, err)
  end
end)
```

Key points:

* Use `fibers.run(function(scope) ... end)` as the entry point.
* Use `fibers.perform(op)` to run `Op`s in a way that respects scope cancellation and fail-fast semantics.
* The command’s lifetime is bound to the current scope: when that scope joins, the process is shut down and its resources cleaned up.

If you need non-raising scope-aware execution, use `fibers.try_perform(op)`, which returns a status tag first (see below).

---

## Constructing commands

The main entry point is `exec.command`. It supports both table and positional forms:

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

In table form, the fields are typically:

* `spec[1]`, `spec[2]`, … – argv elements
* `cwd` – working directory (string or `nil`)
* `env` – environment variables (`string -> string|nil`)
* `flags` – backend-specific flags (for example `setsid`)
* `stdin`, `stdout`, `stderr` – stdio configuration (see below)
* `shutdown_grace` – grace period in seconds for shutdown, default implementation-defined

There may also be setter methods which can be used before the command is started:

```lua
cmd:set_cwd("/var/log")
   :set_env{ LANG = "C" }
   :set_stdin("null")
   :set_stdout("pipe")
   :set_stderr("stdout")
   :set_shutdown_grace(5.0)
```

(All setters are expected to raise if the command has already started.)

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

Passing a `Stream` instance uses the underlying file descriptor for that stream. In that case the `Command` does not own the stream and will not close it automatically.

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

-- Direct stdout to an existing stream; inherit stderr
local out_file = assert(file.open("out.log", "w"))
local cmd2 = exec.command{
  "my-tool",
  stdout = out_file, -- user-supplied stream
}

-- Capture stdout and stderr together (merged)
local cmd3 = exec.command{
  "my-tool",
  stdout = "pipe",
  stderr = "stdout",
}
```

If you set `stdout = "pipe"` or `stderr = "pipe"`, the backend will create `Stream`s for you, and the `Command` will typically own and close them during cleanup.

---

## Inspecting command state

The main introspection methods are typically:

```lua
local st, code_or_sig, err = cmd:status()
local pid                  = cmd:pid()
local argv_copy            = cmd:argv()
```

Status values are typically:

* `"pending"` – created but not yet started.
* `"running"` – process started and still running.
* `"exited"` – process exited normally.
* `"signalled"` – process terminated by a signal.
* `"failed"` – failed to start or manage the process.

For `"exited"` and `"signalled"`:

* exit code (integer) for `"exited"`;
* signal number (integer) for `"signalled"`.

For `"failed"` the error is typically an error string.

Many implementations start the process lazily: the process may only be started when you first perform `run_op`, `shutdown_op`, `output_op`, or when you request piped streams.

---

## Accessing stdio streams

You can obtain `Stream`s for the child’s stdio via:

```lua
local stdin_stream,  e1 = cmd:stdin_stream()
local stdout_stream, e2 = cmd:stdout_stream()
local stderr_stream, e3 = cmd:stderr_stream()
```

Typical behaviour:

* If the mode is `"inherit"` or `"null"`, these functions return `nil`.
* If the mode is a user-supplied stream, you get that stream back.
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

  fibers.spawn(function()
    while true do
      local line, lerr = fibers.perform(out_stream:read_line_op())
      if not line then
        break
      end
      print("[child]", line)
    end
  end)

  local st, code, sig, cerr = fibers.perform(cmd:run_op())
  print("child finished:", st, code, sig, cerr)
end)
```

---

## Waiting for completion

To wait for a process to finish, use `run_op`:

```lua
local st, code, sig, err = fibers.perform(cmd:run_op())
```

Semantics:

* If the process has not yet been started, `run_op` starts it.
* If the process is already complete, `run_op` may resolve immediately.
* Typical results are:

  * `st` – `"exited"`, `"signalled"` or `"failed"`.
  * `code` – exit code (for `"exited"`) or `nil`.
  * `sig` – signal number (for `"signalled"`) or `nil`.
  * `err` – error string for `"failed"`, otherwise `nil`.

Because `run_op` is an `Op`, it participates in `choice` and respects scope cancellation when performed via `fibers.perform`.

### Scope-aware, non-raising form

If you want to observe scope failure/cancellation as data (rather than as a raised error), use `fibers.try_perform`:

```lua
local scope_st, a, b, c, d = fibers.try_perform(cmd:run_op())
-- scope_st is: "ok" | "failed" | "cancelled"
-- on "ok": a,b,c,d are the run_op results
-- on not-ok: a is the scope’s primary error/reason
```

---

## Graceful shutdown

To request a graceful shutdown, use `shutdown_op`:

```lua
-- Optional override of the grace period (seconds)
local st, code, sig, err = fibers.perform(cmd:shutdown_op(5.0))
```

Typical behaviour:

1. Ensure the process has been started.
2. Send a polite termination request (backend-defined).
3. Wait for exit within the grace period.
4. If the process has not exited, send a more forceful kill.
5. Wait for final completion and return the final status.

`shutdown_op` is suitable in normal control flow (for example when stopping a worker) and is also used during scope cleanup.

---

## Capturing output

### `output_op` – stdout only

`output_op` runs the process to completion while capturing all data from stdout into a single string:

```lua
local out, st, code, sig, err = fibers.perform(cmd:output_op())
```

Typical behaviour:

* If `stdout` would otherwise be inherited, `output_op` arranges for it to be piped for capture.
* The process is started if necessary.
* All data from the stdout stream is read (typically using stream operations).
* The operation then waits for the process to exit.
* It returns `out` plus the same status tuple as `run_op`.

Example:

```lua
local cmd = exec.command("sh", "-c", "echo hello; exit 0")
local out, st, code, sig, err = fibers.perform(cmd:output_op())

if st == "exited" and code == 0 then
  print("child said:", out)
else
  print("child failed:", st, code, sig, err)
end
```

### `combined_output_op` – stdout and stderr together

If you want stdout and stderr merged, use `combined_output_op`:

```lua
local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
```

Typical behaviour:

* `stderr` is directed to `stdout` for the lifetime of the operation (subject to existing configuration constraints).
* Capture and completion semantics match `output_op`.

---

## Sending signals directly

If you want to send a signal yourself, a typical interface is:

```lua
local ok, err = cmd:kill()        -- default forceful kill (backend-defined)
-- or, if supported:
local ok2, err2 = cmd:kill("TERM")
```

Exact signal naming and behaviour are backend dependent. Prefer `shutdown_op` where you want portable behaviour.

---

## Scope-bound lifetime

A `Command` is owned by the scope in which it is created. In practical terms:

* Create commands in the scope that should own their lifetime.
* Perform process ops via `fibers.perform` (or `scope:perform` if you are explicitly holding a scope).
* Do not keep `Command` instances beyond the lifetime of their owning scope.

When a scope joins, its finalisers run in a non-interruptible join worker. This provides a reliable place for process cleanup: any processes and backend resources owned by the scope can be shut down deterministically even if the scope has already been cancelled.

---

## Typical patterns

### Fire-and-wait with captured output

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  local cmd = exec.command("uname", "-a")
  local out, st, code, sig, err = fibers.perform(cmd:output_op())

  if st == "exited" and code == 0 then
    print(out)
  else
    print("uname failed:", st, code, sig, err)
  end
end)
```

### Run a long-lived process in a child scope and observe the boundary

Use `fibers.run_scope` when you want the scope outcome as values:

```lua
local fibers = require 'fibers'
local exec   = require 'fibers.exec'

fibers.run(function(scope)
  local scope_st, report, proc_st, code, sig, perr =
    fibers.run_scope(function(child)
      local cmd = exec.command{
        "some-daemon", "--foreground",
        stdout = "inherit",
        stderr = "inherit",
      }
      return fibers.perform(cmd:run_op())
    end)

  if scope_st ~= "ok" then
    -- The child scope failed or was cancelled; third value is the primary error/reason.
    local primary = proc_st
    print("worker scope not ok:", scope_st, tostring(primary))
  else
    -- The child scope body returned normally; proc_st/code/sig/perr are from run_op.
    print("process finished:", proc_st, code, sig, perr)
  end

  if report and report.extra_errors and #report.extra_errors > 0 then
    print("secondary errors during join:")
    for i, e in ipairs(report.extra_errors) do
      print("  [" .. i .. "]", e)
    end
  end
end)
```

This pattern separates “scope outcome” from “process exit status”: the child scope can be `"ok"` even if the process exits non-zero, because that exit status is regular return data rather than a Lua error.

---

## Summary

* Create commands inside a scope (that is, inside a fiber).
* Use `fibers.perform(cmd:run_op())`, `fibers.perform(cmd:shutdown_op())`, and `fibers.perform(cmd:output_op())` as the normal interaction style.
* Use `fibers.run_scope` / `fibers.run_scope_op` when you want process work to be a structured subtree that can be joined, reported on, and composed with other events.
* Rely on scope finalisers for deterministic cleanup: processes and owned streams do not leak past the scope that created them.
