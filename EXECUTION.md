# Process execution (`fibers.io.exec`)

This document explains how to start and manage external processes with `fibers`.

It focuses on the “normal user” surface:

* `fibers.run(main_fn, ...)` starts the scheduler and a root scope.
* `fibers.spawn(fn, ...)` starts a new fiber in the current scope.
* `fibers.perform(op)` performs an operation (and will raise if the current scope is failed/cancelled).
* `fibers.run_scope(body_fn, ...)` runs a child scope and returns its outcome as values.
* `fibers.run_scope_op(body_fn, ...)` represents a child-scope boundary as an `Op`.

The process API lives in `fibers.io.exec`:

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"
```

---

## What you get

The exec subsystem provides:

* A `Command` object representing one external process.
* **Scope-owned lifetime**: a `Command` belongs to the scope in which it was created.
* Configurable `stdin`/`stdout`/`stderr`:

  * inherit from the parent process,
  * connect to `/dev/null`,
  * pipe via `Stream`,
  * reuse an existing stream (including `stderr = "stdout"`).
* Ops for:

  * waiting for completion,
  * shutdown with a grace period then escalation,
  * capturing output as a string.

Backends vary by platform (pidfd where available, SIGCHLD fallbacks, etc.). The important bit is that the *shape* is stable: you get ops that compose with the rest of the library.

---

## The one rule: create commands inside a fiber

`exec.command(...)` must be called from inside a fiber. In practice: inside `fibers.run`, inside a function spawned by `fibers.spawn`, or inside `fibers.run_scope`.

Basic pattern:

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"

fibers.run(function()
  local cmd = exec.command("ls", "-1")

  local out, st, code, sig, err = fibers.perform(cmd:output_op())

  if st == "exited" and code == 0 then
    print("ls output:\n" .. out)
  else
    print("ls failed:", st, code, sig, err)
  end
end)
```

Key points:

* You interact with processes by performing ops: `cmd:run_op()`, `cmd:shutdown_op()`, `cmd:output_op()`, …
* The command’s lifetime is bound to the current scope: when that scope joins, the process is shut down and its resources are cleaned up.

There is no top-level `try_perform`. If you want “status as values”, use an explicit boundary (`run_scope` / `run_scope_op`).

---

## Constructing commands

`exec.command` supports both table and positional forms:

```lua
local exec = require "fibers.io.exec"

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

Table fields:

* `spec[1]`, `spec[2]`, …: argv elements
* `cwd`: working directory (string or nil)
* `env`: environment (`string -> string|nil`)
* `flags`: backend-specific flags (e.g. `setsid`)
* `stdin`, `stdout`, `stderr`: stdio config (next section)
* `shutdown_grace`: default grace period in seconds for shutdown

You can also configure with setters before the command starts:

```lua
cmd:set_cwd("/var/log")
   :set_env{ LANG = "C" }
   :set_stdin("null")
   :set_stdout("pipe")
   :set_stderr("stdout")
   :set_shutdown_grace(5.0)
```

All setters raise if the command has already started.

---

## Stdio configuration

Each of `stdin`, `stdout`, `stderr` can be:

* a string mode, or
* an existing `Stream`.

String modes:

* `"inherit"`: use the parent process’s fd (default)
* `"null"`: connect to `/dev/null`
* `"pipe"`: create a new pipe and expose the parent end as a `Stream`
* `"stdout"`: *stderr only*; share the same destination as stdout

Passing a `Stream` uses its underlying fd. In that case the `Command` does **not** own the stream and will not close it.

Examples:

```lua
local file = require "fibers.io.file"
local exec = require "fibers.io.exec"

-- Discard all output, no input.
local cmd1 = exec.command{
  "my-tool",
  stdin  = "null",
  stdout = "null",
  stderr = "null",
}

-- Direct stdout to an existing stream; inherit stderr.
local out_file = assert(file.open("out.log", "w"))
local cmd2 = exec.command{
  "my-tool",
  stdout = out_file, -- user-supplied stream (not owned)
}

-- Capture stdout and stderr together.
local cmd3 = exec.command{
  "my-tool",
  stdout = "pipe",
  stderr = "stdout",
}
```

If you configure `"pipe"`, the backend creates streams and the command typically owns and closes them during cleanup.

---

## Command state and laziness

Introspection:

```lua
local st, code_or_sig, err = cmd:status()
local pid                  = cmd:pid()
local argv_copy            = cmd:argv()
```

Status values:

* `"pending"`: created but not started
* `"running"`: started and still running
* `"exited"`: exited normally (code is available)
* `"signalled"`: terminated by a signal (signal number is available)
* `"failed"`: failed to start or manage the process (err string available)

Many commands start lazily. The process may not actually be spawned until you:

* perform `run_op` / `shutdown_op` / `output_op`, or
* request a piped stream (`stdout_stream()` etc. when configured as `"pipe"`).

This is intentional: the command is a plan until you first need it to be real.

---

## Getting stdio streams

You can ask for streams:

```lua
local stdin_s,  e1 = cmd:stdin_stream()
local stdout_s, e2 = cmd:stdout_stream()
local stderr_s, e3 = cmd:stderr_stream()
```

Typical behaviour:

* `"inherit"` / `"null"`: returns `nil`
* user-supplied stream: returns that stream
* `"pipe"`: starts the process if necessary and returns a `Stream`
* `stderr = "stdout"`: `stderr_stream()` delegates to `stdout_stream()`

Example: stream stdout line-by-line while the child runs:

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"

fibers.run(function()
  local cmd = exec.command{
    "sh", "-c", "printf 'a\nb\nc\n'; sleep 0.1",
    stdout = "pipe",
    stderr = "stdout",
  }

  local out = assert(cmd:stdout_stream())

  fibers.spawn(function()
    while true do
      local line, err = fibers.perform(out:read_line_op())
      if err then error(err) end
      if not line then break end -- EOF
      print("[child]", line)
    end
  end)

  local st, code, sig, err = fibers.perform(cmd:run_op())
  print("child finished:", st, code, sig, err)
end)
```

---

## Waiting for completion (`run_op`)

To wait for the process:

```lua
local st, code, sig, err = fibers.perform(cmd:run_op())
```

Semantics:

* Starts the process if it hasn’t started yet.
* Resolves immediately if already complete.
* Returns:

  * `st`: `"exited" | "signalled" | "failed"`
  * `code`: exit code for `"exited"`, else nil
  * `sig`: signal number for `"signalled"`, else nil
  * `err`: error string for `"failed"`, else nil

Because it’s an op, you can race it against timeouts or other events.

If the *scope* fails/cancels while you are waiting, `fibers.perform` raises (that’s how “don’t outlive your scope” shows up in real code).

---

## Graceful shutdown (`shutdown_op`)

To ask the process to stop politely, then escalate:

```lua
local st, code, sig, err = fibers.perform(cmd:shutdown_op(5.0)) -- grace seconds
```

Typical behaviour:

1. Ensure the process is started.
2. Send a polite termination request (backend-defined).
3. Wait for exit within the grace period.
4. If still running, send a forceful kill.
5. Wait for final completion and return the final status.

`shutdown_op` is useful in normal control flow (stopping a worker) and is also what scope cleanup will use when a command is still running at scope exit.

---

## Capturing output

### `output_op` (stdout only)

Capture all stdout and wait for completion:

```lua
local out, st, code, sig, err = fibers.perform(cmd:output_op())
```

Behaviour:

* If stdout is currently `"inherit"`, `output_op` will arrange piping for capture.
* Reads stdout to EOF (using stream ops).
* Waits for process completion.
* Returns `out` plus the same status tuple as `run_op`.

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

### `combined_output_op` (stdout + stderr)

Merge stderr into stdout and capture:

```lua
local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
```

This is equivalent to “stderr goes to stdout for the lifetime of this operation”, subject to the usual configuration constraints.

---

## Sending signals directly (`kill`)

You can send a signal yourself:

```lua
local ok, err = cmd:kill()        -- default forceful kill (backend-defined)
-- or, if supported:
local ok2, err2 = cmd:kill("TERM")
```

Signal naming and behaviour are backend-dependent. Prefer `shutdown_op` when you want portable, structured behaviour.

---

## Scope-bound lifetime (the important bit)

A `Command` is owned by the scope in which it is created.

Practical implications:

* Create commands in the scope that should own them.
* Don’t stash a `Command` and keep using it after the scope that created it has joined.
* Expect operations performed under a cancelled/failed scope to raise: that is the mechanism that prevents “zombie work”.

Cleanup happens during scope join, in a non-interruptible join worker. That is exactly where processes belong: if a scope is exiting (successfully or not), its commands are shut down and their owned resources are closed deterministically.

---

## Patterns

### Fire-and-wait with captured output

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"

fibers.run(function()
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

This separates “did the scope run cleanly?” from “what did the process do?”:

```lua
local fibers = require "fibers"
local exec   = require "fibers.io.exec"

fibers.run(function()
  local scope_st, report, proc_st, code, sig, perr =
    fibers.run_scope(function()
      local cmd = exec.command{
        "some-daemon", "--foreground",
        stdout = "inherit",
        stderr = "inherit",
      }
      return fibers.perform(cmd:run_op())
    end)

  if scope_st ~= "ok" then
    -- The scope failed/cancelled; proc_st is the primary error/reason.
    print("worker scope not ok:", scope_st, tostring(proc_st))
  else
    -- Scope ran normally; proc_* are the process results.
    print("process finished:", proc_st, code, sig, perr)
  end

  if report and report.extra_errors and #report.extra_errors > 0 then
    print("secondary errors during join:")
    for i, e in ipairs(report.extra_errors) do
      print(("  [%d] %s"):format(i, tostring(e)))
    end
  end
end)
```

---

## Summary

* Create commands inside a scope (i.e. inside a fiber).
* Interact with them via ops: `run_op`, `shutdown_op`, `output_op`, `combined_output_op`.
* Perform those ops with `fibers.perform`, and let scope failure/cancellation raise naturally.
* Use `run_scope` / `run_scope_op` when you want structured outcomes as values.
* Rely on scope finalisers for deterministic cleanup: processes and owned streams should not leak past the scope that created them.
