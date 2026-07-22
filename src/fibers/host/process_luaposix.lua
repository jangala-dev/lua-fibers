-- Process-honest luaposix child-process provider.
--
-- The close-on-exec error pipe proves successful exec. The provider owns child
-- identity, signalling and exactly-once waitpid; fibers.process owns policy,
-- streams, escalation and structured settlement.

local HostError = require('fibers.host.error')
local ProcessCore = require('fibers.host.process_core')
local ProcessIO = require('fibers.host.process_io_core')
local IOAudit = require('fibers.internal.io_audit')
local Family = require('fibers.host.family')

local function unsupported(reason)
  return Family.unsupported('fibers.host.process_luaposix', reason, {
    'start_process',
  })
end

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_errno, errno = pcall(require, 'posix.errno')
local ok_signal, signal = pcall(require, 'posix.signal')
local ok_wait, syswait = pcall(require, 'posix.sys.wait')
local ok_stdlib, stdlib = pcall(require, 'posix.stdlib')
if
  not (ok_unistd and ok_fcntl and ok_errno and ok_signal and ok_wait and ok_stdlib)
  or type(unistd) ~= 'table'
  or type(fcntl) ~= 'table'
  or type(errno) ~= 'table'
  or type(signal) ~= 'table'
  or type(syswait) ~= 'table'
  or type(stdlib) ~= 'table'
then
  return unsupported('requires luaposix unistd, fcntl, errno, signal, wait and stdlib modules')
end

local BitOps = require('fibers.internal.bitops')
local bit, bit_error = BitOps.resolve()
if not bit then
  return unsupported(bit_error)
end
local Fd = require('fibers.host.fd_luaposix')
local PosixError = require('fibers.host.luaposix_error')
local Provider = {}

local err_message = PosixError.message

local function set_flag(fd, get_cmd, set_cmd, flag, enabled)
  local current, err, eno = fcntl.fcntl(fd, get_cmd)
  if current == nil then
    return nil, err, eno
  end
  local next_flags = enabled and bit.bor(current, flag) or bit.band(current, bit.bnot(flag))
  local ok, set_err, set_eno = fcntl.fcntl(fd, set_cmd, next_flags)
  if ok == nil then
    return nil, set_err, set_eno
  end
  return true
end

local function set_cloexec(fd, enabled)
  return set_flag(fd, fcntl.F_GETFD, fcntl.F_SETFD, fcntl.FD_CLOEXEC, enabled ~= false)
end

local function close_fd(fd)
  if fd == nil or fd < 0 then
    return true
  end
  while true do
    local ok, err, eno = unistd.close(fd)
    if ok ~= nil then
      return true
    end
    if eno ~= errno.EINTR then
      return nil, err, eno
    end
  end
end

local function raw_pipe()
  local r, w, err, eno = unistd.pipe()
  if r == nil then
    return nil, nil, err, eno
  end
  local ok_r, err_r, eno_r = set_cloexec(r, true)
  local ok_w, err_w, eno_w = set_cloexec(w, true)
  if not ok_r or not ok_w then
    close_fd(r)
    close_fd(w)
    return nil, nil, err_r or err_w, eno_r or eno_w
  end
  return r, w
end

local function write_all(fd, bytes)
  local offset = 0
  while offset < #bytes do
    local n, err, eno = unistd.write(fd, bytes, #bytes - offset, offset)
    if n == nil then
      if eno ~= errno.EINTR then
        return nil, err, eno
      end
    else
      offset = offset + n
    end
  end
  return true
end

local function child_fail(error_write, stage, eno)
  write_all(error_write, tostring(stage) .. ':' .. tostring(eno or 0) .. '\n')
  unistd._exit(127)
end

local function setup_environment_child(spec)
  if spec.env_mode == 'replace' then
    local current, get_err, get_eno = stdlib.getenv()
    if current == nil then
      return nil, get_err, get_eno
    end
    for name in pairs(current) do
      local ok, err, eno = stdlib.setenv(name, nil)
      if ok == nil then
        return nil, err, eno
      end
    end
  end
  for _, name in ipairs(spec.unset_env or {}) do
    local ok, err, eno = stdlib.setenv(tostring(name), nil)
    if ok == nil then
      return nil, err, eno
    end
  end
  for name, value in pairs(spec.env or {}) do
    local ok, err, eno = stdlib.setenv(tostring(name), tostring(value))
    if ok == nil then
      return nil, err, eno
    end
  end
  return true
end

local signals = ProcessCore.signals({
  hup = signal.SIGHUP,
  int = signal.SIGINT,
  quit = signal.SIGQUIT,
  kill = signal.SIGKILL,
  usr1 = signal.SIGUSR1,
  usr2 = signal.SIGUSR2,
  pipe = signal.SIGPIPE,
  alrm = signal.SIGALRM,
  term = signal.SIGTERM,
  chld = signal.SIGCHLD,
  cont = signal.SIGCONT,
  stop = signal.SIGSTOP,
})

local function reap_process(self)
  if self.status then
    return self.status
  end
  local pid, how, value = syswait.wait(self._pid, syswait.WNOHANG)
  if pid == nil then
    local err, eno = how, value
    return nil,
      HostError.system('process', 'reap', err_message('wait failed', err, eno), nil, eno, {
        pid = self._pid,
      })
  end
  if pid == 0 or how == 'running' or how == 'stopped' then
    return nil, HostError.would_block('process', 'reap', { pid = self._pid })
  end
  local status
  if how == 'exited' then
    status = ProcessCore.exited(value)
  elseif how == 'killed' or how == 'signaled' or how == 'signalled' then
    status = ProcessCore.signalled(signals, value)
  else
    return nil,
      HostError.protocol('process', 'reap', 'unexpected wait status', {
        pid = self._pid,
        status = how,
        value = value,
      })
  end
  self.status, self.reaped = status, true
  return status
end

local function signal_process(self, number, target)
  local ok, err, eno
  if target == 'group' and type(signal.killpg) == 'function' then
    ok, err, eno = signal.killpg(math.abs(self.group_id or self._pid), number)
  else
    local pid = target == 'group' and -math.abs(self.group_id or self._pid) or self._pid
    ok, err, eno = signal.kill(pid, number)
  end
  if ok == nil then
    return nil,
      HostError.system('process', 'signal', err_message('kill failed', err, eno), nil, eno, {
        pid = self._pid,
        signal = number,
        target = target,
      })
  end
  return true
end

local HostProcess = ProcessCore.class({ signals = signals, reap = reap_process, signal = signal_process })

local function support_probe()
  local required = {
    unistd.fork,
    unistd.execp,
    unistd._exit,
    unistd.pipe,
    unistd.dup2,
    unistd.close,
    unistd.read,
    unistd.write,
    unistd.chdir,
    unistd.setpid,
    unistd.sysconf,
    fcntl.fcntl,
    fcntl.open,
    signal.kill,
    syswait.wait,
    stdlib.getenv,
    stdlib.setenv,
  }
  for i = 1, #required do
    if type(required[i]) ~= 'function' then
      return nil
    end
  end
  if
    fcntl.F_GETFD == nil
    or fcntl.F_SETFD == nil
    or not fcntl.FD_CLOEXEC
    or fcntl.F_GETFL == nil
    or fcntl.F_SETFL == nil
    or fcntl.O_NONBLOCK == nil
    or syswait.WNOHANG == nil
    or not Fd.is_supported()
  then
    return nil
  end
  return true
end

function Provider.is_supported()
  local ok = support_probe()
  return not not ok, ok and nil or 'required luaposix process functions unavailable'
end
function Provider.support_reason()
  local ok, reason = Provider.is_supported()
  return ok and nil or reason
end

local function close_child_fds(spec, error_write)
  local keep = { [error_write] = true }
  local ordered = { error_write }
  for _, value in ipairs(spec.pass_fds or {}) do
    local fd = tonumber(value)
    if not fd or fd < 0 or fd ~= math.floor(fd) then
      return nil, nil, errno.EINVAL
    end
    if fd >= 3 and not keep[fd] then
      keep[fd] = true
      ordered[#ordered + 1] = fd
    end
    if fd >= 3 then
      local ok, err, eno = set_cloexec(fd, false)
      if not ok then
        return nil, err, eno
      end
    end
  end
  if spec.close_fds == false then
    return true
  end
  table.sort(ordered)
  local max_fd = unistd.sysconf(unistd._SC_OPEN_MAX or 4)
  max_fd = tonumber(max_fd) or 1024
  for fd = 3, max_fd - 1 do
    if not keep[fd] then
      unistd.close(fd)
    end
  end
  return true
end

local function setup_stdio_child(stdio, error_write)
  return ProcessIO.install_child(stdio, {
    targets = { stdin = 0, stdout = 1, stderr = 2 },
    stdout = 1,
    same = function(a, b)
      return a == b
    end,
    duplicate = function(source, target)
      local ok, err, eno = unistd.dup2(source, target)
      return ok ~= nil, err, eno
    end,
    open_null = function(which)
      return fcntl.open('/dev/null', which == 'stdin' and fcntl.O_RDONLY or fcntl.O_WRONLY, 0)
    end,
    keep = function(fd)
      return fd == 0 or fd == 1 or fd == 2 or fd == error_write
    end,
    close = unistd.close,
  })
end

local function build_argt(argv)
  local out = { [0] = argv[1] }
  for i = 2, #argv do
    out[i - 1] = argv[i]
  end
  return out
end

local function wait_blocking(pid)
  while true do
    local got, how, value = syswait.wait(pid)
    if got ~= nil then
      return got, how, value
    end
    local err, eno = how, value
    if eno ~= errno.EINTR then
      return nil, err, eno
    end
  end
end

local function kill_and_reap(pid)
  pcall(signal.kill, pid, signal.SIGKILL or 9)
  wait_blocking(pid)
end

local launch_actions = {
  cwd = 'chdir',
  session = 'setsid',
  group = 'setpgid',
  environment = 'environment',
  stdio = 'stdio',
  close_fds = 'close_fds',
  exec = 'exec',
}

function Provider.start_process(host, spec)
  if not Provider.is_supported() then
    return nil, nil, HostError.unsupported('host', 'process', { host = host.name })
  end

  local stdio, parent_fds, stdio_err = ProcessIO.open(spec, function(which)
    local r, w, err, eno = raw_pipe()
    if not r then
      return nil,
        nil,
        HostError.system('process', 'pipe', err_message('pipe failed', err, eno), nil, eno, {
          stream = which,
        })
    end
    return r, w
  end, close_fd)
  if not stdio then
    return nil, nil, stdio_err
  end

  local error_read, error_write, pipe_err, pipe_eno = raw_pipe()
  if not error_read then
    for _, fd in ipairs(stdio.all) do
      close_fd(fd)
    end
    return nil,
      nil,
      HostError.system('process', 'exec_pipe', err_message('pipe failed', pipe_err, pipe_eno), nil, pipe_eno)
  end

  local pid, fork_err, fork_eno = unistd.fork()
  if pid == nil then
    close_fd(error_read)
    close_fd(error_write)
    for _, fd in ipairs(stdio.all) do
      close_fd(fd)
    end
    return nil,
      nil,
      HostError.system('process', 'fork', err_message('fork failed', fork_err, fork_eno), nil, fork_eno)
  end

  if pid == 0 then
    unistd.close(error_read)
    if spec.cwd then
      local ok, _, eno = unistd.chdir(spec.cwd)
      if ok == nil then
        child_fail(error_write, 'cwd', eno)
      end
    end
    if spec.new_session then
      local ok, _, eno = unistd.setpid('s', 0)
      if ok == nil then
        child_fail(error_write, 'session', eno)
      end
    elseif spec.process_group == 'new' then
      local ok, _, eno = unistd.setpid('p', 0, 0)
      if ok == nil then
        child_fail(error_write, 'group', eno)
      end
    elseif type(spec.process_group) == 'number' then
      local ok, _, eno = unistd.setpid('p', 0, spec.process_group)
      if ok == nil then
        child_fail(error_write, 'group', eno)
      end
    end
    local env_ok, _, env_eno = setup_environment_child(spec)
    if not env_ok then
      child_fail(error_write, 'environment', env_eno)
    end
    local stdio_ok, _, stdio_eno = setup_stdio_child(stdio, error_write)
    if not stdio_ok then
      child_fail(error_write, 'stdio', stdio_eno)
    end
    local close_ok, _, close_eno = close_child_fds(spec, error_write)
    if not close_ok then
      child_fail(error_write, 'close_fds', close_eno)
    end
    local _, _, exec_eno = unistd.execp(spec.argv[1], build_argt(spec.argv))
    child_fail(error_write, 'exec', exec_eno)
  end

  close_fd(error_write)
  ProcessIO.close_child_ends(stdio, parent_fds, close_fd)

  local handshake = ''
  while true do
    local chunk, read_err, read_eno = unistd.read(error_read, 256)
    if chunk ~= nil then
      if chunk == '' then
        break
      end
      handshake = handshake .. chunk
      if #handshake > 4096 then
        break
      end
    elseif read_eno ~= errno.EINTR then
      close_fd(error_read)
      kill_and_reap(pid)
      for _, fd in pairs(parent_fds) do
        close_fd(fd)
      end
      return nil,
        nil,
        HostError.system(
          'process',
          'exec_handshake',
          err_message('handshake read failed', read_err, read_eno),
          nil,
          read_eno
        )
    end
  end
  close_fd(error_read)

  if handshake ~= '' then
    wait_blocking(pid)
    for _, fd in pairs(parent_fds) do
      close_fd(fd)
    end
    local stage, number = handshake:match('^([%w_]+):(%d+)\n?$')
    if not stage then
      return nil,
        nil,
        HostError.protocol('process', 'exec_handshake', 'invalid child setup failure', {
          argv = spec.argv,
          payload = handshake,
        })
    end
    local eno = tonumber(number)
    local action = launch_actions[stage] or 'exec_handshake'
    return nil,
      nil,
      HostError.system('process', action, err_message(action .. ' failed', nil, eno), nil, eno, {
        argv = spec.argv,
      })
  end

  local endpoints, wrap_err = ProcessIO.wrap({
    host = host,
    name = spec.name,
    pid = pid,
    parents = parent_fds,
    wrap = Fd.new,
    close_raw = close_fd,
    cloexec = true,
    abort = function()
      kill_and_reap(pid)
    end,
  })
  if not endpoints then
    return nil, nil, wrap_err
  end

  local process = setmetatable({
    name = spec.name or ('process-' .. tostring(pid)),
    _pid = pid,
    group_id = (spec.new_session or spec.process_group == 'new') and pid
      or (type(spec.process_group) == 'number' and spec.process_group or nil),
    poll_interval = spec.poll_interval or 0.025,
    status = nil,
    reaped = false,
    closed = false,
  }, HostProcess)
  IOAudit.created(process, { kind = 'process_handle' })
  return process, endpoints
end

return Provider
