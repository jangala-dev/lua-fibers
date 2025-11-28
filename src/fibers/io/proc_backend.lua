-- fibers/io/proc_backend.lua
--
-- Low-level OS process backend for fibers.process.
--
-- Linux-specific: uses fork + execp + pidfd_open + wait(WNOHANG).
--
---@module 'fibers.io.proc_backend'

local sc = require 'fibers.utils.syscall'

---@class ProcSpec
---@field argv string[]                          -- argv[1] is executable
---@field env table<string,string|nil>|nil       -- env overrides/unsets; nil: inherit
---@field cwd string|nil                         -- working directory for child
---@field stdin_fd integer|nil                   -- child stdin fd (nil = inherit)
---@field stdout_fd integer|nil                  -- child stdout fd (nil = inherit)
---@field stderr_fd integer|nil                  -- child stderr fd (nil = inherit)
---@field flags table|nil                        -- optional flags, e.g. { setsid = true }

---@class ProcBackend
---@field pid integer
---@field pidfd integer
---@field exited boolean
---@field status integer|nil           -- raw status / code / signal
---@field code integer|nil             -- exit code if exited normally
---@field signal integer|nil           -- signal number if killed/stopped
---@field err string|nil
local ProcBackend = {}
ProcBackend.__index = ProcBackend

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

local function errno_msg(prefix, err, errno)
  return err or (prefix .. " (errno " .. tostring(errno) .. ")")
end

local function must_ok(ok)
  if not ok then
    sc._exit(127)
  end
end

local function build_argt(argv)
  local cmd = assert(argv[1], "ProcSpec.argv[1] must be executable")
  local argt = {}
  argt[0] = cmd
  for i = 2, #argv do
    argt[i - 1] = argv[i]
  end
  return cmd, argt
end

--- Duplicate src_fd onto dest_fd in the child.
local function setup_child_fd(src_fd, dest_fd)
  if src_fd == nil or src_fd == dest_fd then
    return
  end
  must_ok(sc.dup2(src_fd, dest_fd))
end

--- Apply environment overrides in the child.
---@param env table<string, string|nil>
local function apply_child_env(env)
  for name, value in pairs(env) do
    must_ok(sc.setenv(name, value and tostring(value) or nil))
  end
end

---@param spec ProcSpec
local function child_exec(spec)
  if spec.cwd then
    must_ok(sc.chdir(spec.cwd))
  end

  if spec.flags and spec.flags.setsid then
    must_ok(sc.setpid("s", 0))
  end

  if spec.env then
    apply_child_env(spec.env)
  end

  setup_child_fd(spec.stdin_fd,  0)
  setup_child_fd(spec.stdout_fd, 1)
  setup_child_fd(spec.stderr_fd, 2)

  -- Close child-only descriptors used for stdio, where safe.
  do
    local seen = {}
    for _, fd in ipairs{ spec.stdin_fd, spec.stdout_fd, spec.stderr_fd } do
      if fd and fd > 2 and not seen[fd] then
        seen[fd] = true
        sc.close(fd) -- ignore errors
      end
    end
  end

  local cmd, argt = build_argt(spec.argv)
  sc.execp(cmd, argt)

  sc._exit(127)
end

----------------------------------------------------------------------
-- Public spawn
----------------------------------------------------------------------

---@param spec ProcSpec
---@return ProcBackend|nil backend, string|nil err
local function spawn(spec)
  assert(type(spec) == "table", "ProcBackend.spawn: spec must be a table")
  assert(type(spec.argv) == "table" and spec.argv[1],
    "ProcBackend.spawn: spec.argv must be a non-empty array")

  local pid, err, errno = sc.fork()
  if not pid then
    return nil, errno_msg("fork failed", err, errno)
  end

  if pid == 0 then
    child_exec(spec)
  end

  local pidfd, perr, perrno = sc.pidfd_open(pid, 0)
  if not pidfd then
    sc.kill(pid, sc.SIGKILL)
    sc.wait(pid, 0)
    return nil, errno_msg("pidfd_open failed", perr, perrno)
  end

  local ok, e1 = sc.set_nonblock(pidfd)
  assert(ok, "set_nonblock pidfd failed: " .. tostring(e1))

  ok, e1 = sc.set_cloexec(pidfd)
  assert(ok, "set_cloexec pidfd failed: " .. tostring(e1))

  local retval = setmetatable({
    pid    = pid,
    pidfd  = pidfd,
    exited = false,
    status = nil,
    code   = nil,
    signal = nil,
    err    = nil,
  }, ProcBackend)

  return retval
end

----------------------------------------------------------------------
-- Non-blocking wait
----------------------------------------------------------------------

function ProcBackend:_finalise(status, code, signal, err)
  if not self.exited then
    self.exited = true
    self.status = status
    self.code   = code
    self.signal = signal
    self.err    = err
    self:close()
  end
  return true, self.status, self.code, self.signal, self.err
end

function ProcBackend:nonblock_wait()
  if self.exited then
    return true, self.status, self.code, self.signal, self.err
  end

  local pid, how, v3 = sc.wait(self.pid, sc.WNOHANG)
  if not pid then
    local err, errno = how, v3
    if errno == sc.ECHILD or errno == sc.ESRCH then
      return self:_finalise(nil, nil, nil, nil)
    end
    return self:_finalise(nil, nil, nil, errno_msg("wait failed", err, errno))
  end

  if how == "running" then
    return false, nil, nil, nil, nil
  end

  local status, code, signal
  if how == "exited" then
    status, code, signal = v3, v3, nil
  else
    status, code, signal = v3, nil, v3
  end

  return self:_finalise(status, code, signal, nil)
end

----------------------------------------------------------------------
-- Signalling and close
----------------------------------------------------------------------

function ProcBackend:send_signal(sig)
  sig = sig or sc.SIGTERM

  local ok, err, errno = sc.kill(self.pid, sig)
  if not ok then
    if errno == sc.ESRCH then return true, nil end
    return false, errno_msg("kill failed", err, errno)
  end

  return true, nil
end

function ProcBackend:close()
  if self.pidfd then
    local ok, err = sc.close(self.pidfd)
    self.pidfd = nil
    if not ok then  return false, err end
  end
  return true, nil
end

return {
  ProcBackend = ProcBackend,
  spawn       = spawn,
}
