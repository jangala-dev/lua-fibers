-- fibers/process.lua
--
-- Process abstraction built on top of proc_backend, streams and CML Ops.
--
---@module 'fibers.process'

local sc       = require 'fibers.utils.syscall'
local op       = require 'fibers.op'
local perform  = require 'fibers.performer'.perform
local wait     = require 'fibers.wait'
local file_io  = require 'fibers.io.file'
local proc_mod = require 'fibers.io.proc_backend'
local poller   = require 'fibers.io.poller'
local sleep    = require 'fibers.sleep'

---@class SpawnOptions
---@field argv string[]                          # required, argv[1] is executable
---@field cwd string|nil                         # working directory for child
---@field env table<string,string|nil>|nil       # environment overrides/unsets
---@field flags table|nil                        # passed through to ProcSpec.flags
---@field stdin '"inherit"'|'"null"'|'"pipe"'|nil
---@field stdout '"inherit"'|'"null"'|'"pipe"'|nil
---@field stderr '"inherit"'|'"null"'|'"pipe"'|'"stdout"'|nil

---@class Process
---@field backend ProcBackend|nil
---@field stdin Stream|nil
---@field stdout Stream|nil
---@field stderr Stream|nil
---@field _done boolean
---@field _status integer|nil
---@field _code integer|nil
---@field _signal integer|nil
---@field _err string|nil
local Process = {}
Process.__index = Process

local DEV_NULL = "/dev/null"

--- Build a ProcSpec and derived stdio information.
---
--- On success returns:
---   spec, child_only_set, parent_stdin_fd, parent_stdout_fd, parent_stderr_fd, nil
---
--- On failure due to OS/environment:
---   nil, nil, nil, nil, nil, err
---
--- On programmer error (bad options), raises.
---@param opts SpawnOptions
---@return table|nil spec
---@return table|nil child_only
---@return integer|nil parent_stdin_fd
---@return integer|nil parent_stdout_fd
---@return integer|nil parent_stderr_fd
---@return string|nil err
local function build_proc_spec(opts)
  local argv = assert(opts.argv, "spawn: opts.argv is required")
  assert(type(argv) == "table" and argv[1], "spawn: opts.argv must be a non-empty array")

  local spec = {
    argv      = argv,
    cwd       = opts.cwd,
    env       = opts.env,
    flags     = opts.flags,
    stdin_fd  = nil,
    stdout_fd = nil,
    stderr_fd = nil,
  }

  local opened     = {}  -- all fds opened in this function
  local child_only = {}  -- subset used only in the child
  local parent_fds = {}  -- parent-side pipe ends by name

  local function remember(fd)
    if fd and fd >= 0 then
      opened[fd] = true
    end
    return fd
  end

  local function mark_child_only(fd)
    if fd and fd >= 0 then
      child_only[fd] = true
    end
    return fd
  end

  local function cleanup_all()
    for fd in pairs(opened) do
      sc.close(fd)
    end
  end

  local function fail_env(msg)
    cleanup_all()
    return nil, nil, nil, nil, nil, msg
  end

  local function prog_error(msg)
    -- Programmer error: clean up fds for politeness, then raise.
    cleanup_all()
    error(msg, 3)  -- level 3: attribute to caller of build_proc_spec
  end

  local function open_dev_null(flags)
    local fd, err = sc.open(DEV_NULL, flags, 0)
    if not fd then
      return nil, err or ("failed to open " .. DEV_NULL)
    end
    return remember(fd), nil
  end

  local function make_pipe()
    local rd, wr, perr = sc.pipe()
    if not rd then
      return nil, nil, perr or "pipe() failed"
    end
    remember(rd)
    remember(wr)
    return rd, wr, nil
  end

  local function handle_stream(stream_type, is_output)
    local opt = opts[stream_type] or "inherit"
    if opt == "inherit" then
      return nil  -- no error
    end

    if opt == "null" then
      local flags = is_output and sc.O_WRONLY or sc.O_RDONLY
      local fd, err = open_dev_null(flags)
      if not fd then return err end
      spec[stream_type .. "_fd"] = mark_child_only(fd)
      return nil

    elseif opt == "pipe" then
      local rd, wr, err = make_pipe()
      if not rd then return err or "pipe() failed" end

      if is_output then
        -- child writes, parent reads
        spec[stream_type .. "_fd"] = mark_child_only(wr)
        parent_fds[stream_type]    = rd
      else
        -- child reads, parent writes
        spec[stream_type .. "_fd"] = mark_child_only(rd)
        parent_fds[stream_type]    = wr
      end

      local ok, cerr = sc.set_cloexec(parent_fds[stream_type])
      if not ok then
        return cerr or ("set_cloexec(" .. stream_type .. " parent end) failed")
      end

      return nil

    elseif stream_type == "stderr" and opt == "stdout" then
      -- stderr shares stdout in the child.
      if opts.stdout == "inherit" or opts.stdout == nil then
        spec.stderr_fd = 1
      else
        -- stdout must already have been configured.
        if not spec.stdout_fd then
          prog_error("spawn: stderr='stdout' but stdout not configured")
        end
        spec.stderr_fd = spec.stdout_fd
      end
      return nil

    else
      prog_error("spawn: invalid " .. stream_type .. " option " .. tostring(opt))
    end
  end

  local err = handle_stream("stdin",  false)
  if err then return fail_env(err) end

  err = handle_stream("stdout", true)
  if err then return fail_env(err) end

  err = handle_stream("stderr", true)
  if err then return fail_env(err) end

  return spec, child_only, parent_fds.stdin, parent_fds.stdout, parent_fds.stderr, nil
end

----------------------------------------------------------------------
-- Process spawning
----------------------------------------------------------------------

--- Spawn a new Process according to SpawnOptions.
---@param opts SpawnOptions
---@return Process|nil proc, string|nil err
local function spawn(opts)
  assert(type(opts) == "table", "spawn: opts must be a table")

  local spec, child_only, stdin_fd, stdout_fd, stderr_fd, cfg_err = build_proc_spec(opts)
  if not spec then return nil, cfg_err end

  local backend, spawn_err = proc_mod.spawn(spec)
  if not backend then
    for fd in pairs(child_only or {}) do sc.close(fd) end
    for _, fd in ipairs{ stdin_fd, stdout_fd, stderr_fd } do
      if fd then sc.close(fd) end
    end
    return nil, spawn_err
  end

  -- Child-only ends are not needed in the parent.
  if child_only then
    for fd in pairs(child_only) do sc.close(fd) end
  end

  local function open_stream(fd, mode)
    if not fd then return nil end
    return file_io.fdopen(fd, mode)
  end

  local proc = setmetatable({
    backend = backend,
    stdin   = open_stream(stdin_fd,  sc.O_WRONLY),
    stdout  = open_stream(stdout_fd, sc.O_RDONLY),
    stderr  = open_stream(stderr_fd, sc.O_RDONLY),

    _done   = false,
    _status = nil,
    _code   = nil,
    _signal = nil,
    _err    = nil,
  }, Process)

  return proc, nil
end

--- Spawn wrapped as an Op.
---@param opts SpawnOptions
---@return Op  -- when performed: proc:Process
local function spawn_op(opts)
  return op.guard(function()
    local proc, err = spawn(opts)
    if not proc then error(err or "failed to spawn process") end
    return op.always(proc)
  end)
end

----------------------------------------------------------------------
-- Waiting for exit
----------------------------------------------------------------------

--- Op that completes when the process exits.
--- Returns (status, code, signal, err).
---@return Op
function Process:wait_op()
  local backend = assert(self.backend, "process backend is closed")

  local function step()
    if self._done then
      return true, self._status, self._code, self._signal, self._err
    end

    local exited, status, code, sig, err = backend:nonblock_wait()
    if not exited then
      return false
    end

    self._done   = true
    self._status = status
    self._code   = code
    self._signal = sig
    self._err    = err

    return true, status, code, sig, err
  end

  local function register(task)
    local pidfd = assert(backend.pidfd, "pidfd closed")
    return poller.get():wait(pidfd, "rd", task)
  end

  local function wrap(status, code, sig, err)
    return status, code, sig, err
  end

  return wait.waitable(register, step, wrap)
end

function Process:wait()
  return perform(self:wait_op())
end

function Process:wait_raw()
  return op.perform_raw(self:wait_op())
end

----------------------------------------------------------------------
-- Signalling and status
----------------------------------------------------------------------

function Process:kill(sig)
  if not self.backend then
    return false, "process backend closed"
  end
  return self.backend:send_signal(sig or sc.SIGKILL)
end

function Process:terminate()
  return self:kill(sc.SIGTERM)
end

function Process:status()
  if not self._done then  return "running", nil end

  if self._signal then return "signalled", self._signal end

  return "exited", self._code
end

----------------------------------------------------------------------
-- Closing and shutdown
----------------------------------------------------------------------

function Process:close()
  for _, name in ipairs{ "stdin", "stdout", "stderr" } do
    local s = self[name]
    if s then
      s:close()
      self[name] = nil
    end
  end

  if self.backend then
    self.backend:close()
    self.backend = nil
  end
end

--- Best-effort shutdown: TERM, grace period, then KILL; wait and close.
---@param grace number|nil  -- seconds before SIGKILL; default 1.0
function Process:shutdown(grace)
  grace = grace or 1.0

  if self.backend and not self._done then
    self:terminate()

    local ev = op.boolean_choice(
      self:wait_op():wrap(function(status, code, sig, err)
        return true, status, code, sig, err
      end),
      sleep.sleep_op(grace):wrap(function()
        return false
      end)
    )

    local ok, is_exit = pcall(op.perform_raw, ev)
    if not ok or not is_exit then
      self:kill()
      pcall(function()
        self:wait_raw()
      end)
    end
  end

  self:close()
end

----------------------------------------------------------------------
-- Bracket helper
----------------------------------------------------------------------

---@param spec SpawnOptions
---@param build_op fun(proc: Process): Op
local function with_process(spec, build_op)
  assert(type(build_op) == "function", "with_process: build_op must be a function")

  return op.bracket(
    function()
      local proc, err = spawn(spec)
      if not proc then
        error(err or "failed to spawn process")
      end
      return proc
    end,
    function(proc, aborted)
      if aborted then
        proc:shutdown(1.0)
      else
        pcall(function()
          proc:wait_raw()
        end)
        proc:close()
      end
    end,
    build_op
  )
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
  Process      = Process,
  spawn        = spawn,
  spawn_op     = spawn_op,
  with_process = with_process,
}
