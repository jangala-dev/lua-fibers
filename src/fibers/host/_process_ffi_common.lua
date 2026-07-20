-- Linux/POSIX child-process provider shared by LuaJIT FFI and cffi hosts.
--
-- The provider owns the fork/exec handshake, pipe creation, pid identity and
-- exactly-once waitpid call. The higher Process facility owns policy, Streams,
-- shutdown escalation and structural settlement.

local HostError = require('fibers.host.error')
local IOAudit = require('fibers.internal.io_audit')
local Sleep = require('fibers.sleep')

local Common = {}

local function unsupported(reason)
  return {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
  }
end

local function make_tonumber(ffi)
  local toint = rawget(ffi, 'tonumber') or tonumber
  return function(value)
    return toint(value) or tonumber(value)
  end
end

function Common.new(opts)
  opts = opts or {}
  local ffi = assert(opts.ffi, 'ffi provider required')
  local C = opts.C or ffi.C
  local fd_provider = assert(opts.fd, 'fd provider required')
  local tonumber_c = opts.tonumber_c or make_tonumber(ffi)
  local prefix = opts.error_prefix or 'fibers.host.process_ffi'

  local ok_cdef, cdef_err = pcall(function()
    ffi.cdef([[
      typedef long ssize_t;
      typedef unsigned long size_t;
      typedef int pid_t;
      int fork(void);
      int execvp(const char *file, char *const argv[]);
      void _exit(int status);
      int pipe(int pipefd[2]);
      int dup2(int oldfd, int newfd);
      int close(int fd);
      int open(const char *pathname, int flags, ...);
      int chdir(const char *path);
      int setpgid(pid_t pid, pid_t pgid);
      pid_t setsid(void);
      pid_t waitpid(pid_t pid, int *status, int options);
      int kill(pid_t pid, int sig);
      int fcntl(int fd, int cmd, ...);
      ssize_t read(int fd, void *buf, size_t count);
      ssize_t write(int fd, const void *buf, size_t count);
      long syscall(long number, ...);
      char *strerror(int errnum);
      int setenv(const char *name, const char *value, int overwrite);
      int unsetenv(const char *name);
      int clearenv(void);
      long sysconf(int name);
    ]])
  end)
  if not ok_cdef then
    opts._cdef_err = cdef_err
  end

  local EINTR = 4
  local EAGAIN = 11
  local EINVAL = 22
  local ENOSYS = 38
  local F_GETFD = 1
  local F_SETFD = 2
  local F_GETFL = 3
  local F_SETFL = 4
  local FD_CLOEXEC = 1
  local O_RDONLY = 0
  local O_WRONLY = 1
  local O_RDWR = 2
  local O_NONBLOCK = 2048
  local WNOHANG = 1
  local SIG_NUMBERS = {
    hup = 1,
    int = 2,
    quit = 3,
    kill = 9,
    usr1 = 10,
    usr2 = 12,
    pipe = 13,
    alrm = 14,
    term = 15,
    chld = 17,
    cont = 18,
    stop = 19,
  }
  local SYS_pidfd_open = opts.sys_pidfd_open or 434
  local SYS_close_range = opts.sys_close_range or 436
  local SC_OPEN_MAX = opts.sc_open_max or 4

  local function errno()
    return ffi.errno()
  end

  local function is_null(value)
    if value == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and value == nullptr
  end

  local function strerror(number)
    local ok, value = pcall(function()
      return C.strerror(number)
    end)
    if not ok or is_null(value) then
      return 'errno ' .. tostring(number)
    end
    return ffi.string(value)
  end

  local function vararg_int(value)
    if type(ffi.cast) == 'function' then
      local ok, converted = pcall(ffi.cast, 'int', value)
      if ok then
        return converted
      end
    end
    return value
  end

  local function retry(fn)
    while true do
      local result = tonumber_c(fn())
      if result ~= -1 then
        return result
      end
      local e = errno()
      if e ~= EINTR then
        return nil, e
      end
    end
  end

  local function set_flag(fd, get_cmd, set_cmd, flag, enabled)
    local current, e = retry(function()
      return C.fcntl(fd, get_cmd, vararg_int(0))
    end)
    if current == nil then
      return nil, e
    end
    local BitOps = require('fibers.internal.bitops')
    local bit = assert(BitOps.resolve())
    local value = enabled and bit.bor(current, flag) or bit.band(current, bit.bnot(flag))
    local ok, e2 = retry(function()
      return C.fcntl(fd, set_cmd, vararg_int(value))
    end)
    if ok == nil then
      return nil, e2
    end
    return true
  end

  local function set_cloexec(fd, enabled)
    return set_flag(fd, F_GETFD, F_SETFD, FD_CLOEXEC, enabled ~= false)
  end

  local function set_nonblocking(fd, enabled)
    return set_flag(fd, F_GETFL, F_SETFL, O_NONBLOCK, enabled ~= false)
  end

  local function close_fd(fd)
    if fd == nil or fd < 0 then
      return true
    end
    local ok, e = retry(function()
      return C.close(fd)
    end)
    return ok ~= nil, e
  end

  local function raw_pipe()
    local fds = ffi.new('int[2]')
    if tonumber_c(C.pipe(fds)) ~= 0 then
      local e = errno()
      return nil, nil, e
    end
    local r, w = tonumber_c(fds[0]), tonumber_c(fds[1])
    local ok1, e1 = set_cloexec(r, true)
    local ok2, e2 = set_cloexec(w, true)
    if not ok1 or not ok2 then
      close_fd(r)
      close_fd(w)
      return nil, nil, e1 or e2
    end
    return r, w
  end

  local function c_string(value)
    value = tostring(value)
    local buffer = ffi.new('char[?]', #value + 1)
    ffi.copy(buffer, value, #value)
    buffer[#value] = 0
    return buffer
  end

  local function string_vector(values)
    local buffers = {}
    local vector = ffi.new('char *[?]', #values + 1)
    for i = 1, #values do
      buffers[i] = c_string(values[i])
      vector[i - 1] = buffers[i]
    end
    vector[#values] = nil
    return vector, buffers
  end

  local function setup_environment_child(spec)
    if spec.env_mode == 'replace' then
      if tonumber_c(C.clearenv()) ~= 0 then
        return nil
      end
    end
    for _, key in ipairs(spec.unset_env or {}) do
      if tonumber_c(C.unsetenv(tostring(key))) ~= 0 then
        return nil
      end
    end
    for key, value in pairs(spec.env or {}) do
      if tonumber_c(C.setenv(tostring(key), tostring(value), 1)) ~= 0 then
        return nil
      end
    end
    return true
  end

  local function normalise_signal(signal)
    if type(signal) == 'number' then
      return math.floor(signal)
    end
    local number = SIG_NUMBERS[string.lower(tostring(signal))]
    if not number then
      return nil, HostError.invalid_argument('process', 'signal', { signal = signal })
    end
    return number
  end

  local function decode_status(raw)
    local low = raw % 256
    local signal = low % 128
    if signal == 0 then
      local code = math.floor(raw / 256) % 256
      return { kind = 'exited', code = code, success = code == 0 }
    end
    if signal ~= 127 then
      local names = { [1] = 'HUP', [2] = 'INT', [3] = 'QUIT', [9] = 'KILL', [15] = 'TERM' }
      return {
        kind = 'signalled',
        signal = signal,
        signal_name = names[signal],
        core_dumped = low >= 128,
        success = false,
      }
    end
    return nil
  end

  local HostProcess = {}
  HostProcess.__index = HostProcess

  function HostProcess:bind_runtime(rt)
    self.runtime = rt
    IOAudit.bind(self, rt)
    if self.pidfd and type(self.pidfd.bind_runtime) == 'function' then
      self.pidfd:bind_runtime(rt)
    end
    return self
  end

  function HostProcess:pid()
    return self._pid
  end

  function HostProcess:wait_op()
    if self.status then
      return require('fibers.op').always(true)
    end
    if self.pidfd then
      return self.pidfd:read_ready_op()
    end
    return Sleep.sleep_op(self.poll_interval)
  end

  function HostProcess:reap()
    if self.status then
      return self.status
    end
    local status = ffi.new('int[1]')
    local got, e = retry(function()
      return C.waitpid(self._pid, status, WNOHANG)
    end)
    if got == nil then
      return nil, HostError.system('process', 'reap', strerror(e), nil, e, { pid = self._pid })
    end
    if got == 0 then
      return nil, HostError.would_block('process', 'reap', { pid = self._pid })
    end
    local decoded = decode_status(tonumber_c(status[0]))
    if not decoded then
      return nil, HostError.would_block('process', 'reap', { pid = self._pid })
    end
    self.status = decoded
    self.reaped = true
    return decoded
  end

  function HostProcess:signal(signal, target)
    if self.reaped then
      return nil, HostError.closed('process', 'signal', { pid = self._pid })
    end
    local number, signal_err = normalise_signal(signal)
    if not number then
      return nil, signal_err
    end
    local pid = self._pid
    if target == 'group' then
      pid = -math.abs(self.group_id or self._pid)
    end
    local rc, e = retry(function()
      return C.kill(pid, number)
    end)
    if rc == nil then
      return nil,
        HostError.system('process', 'signal', strerror(e), nil, e, {
          pid = self._pid,
          signal = number,
          target = target,
        })
    end
    return true
  end

  function HostProcess:close(reason)
    if self.closed then
      IOAudit.closing(self, reason)
      IOAudit.closed(self, true, nil, reason)
      return true
    end
    self.closed = true
    IOAudit.closing(self, reason)
    if self.pidfd then
      self.pidfd:close(reason)
      self.pidfd = nil
    end
    IOAudit.closed(self, true, nil, reason)
    return true
  end

  local function pidfd_open(pid)
    local ok, result = pcall(function()
      return tonumber_c(
        C.syscall(ffi.cast('long', SYS_pidfd_open), ffi.cast('int', pid), ffi.cast('unsigned int', 0))
      )
    end)
    if not ok or result == -1 then
      return nil, ok and errno() or ENOSYS
    end
    return result
  end

  local function support_probe()
    local ok = pcall(function()
      return C.fork, C.execvp, C.pipe, C.dup2, C.waitpid, C.kill, C._exit
    end)
    if not ok or not fd_provider.is_supported() then
      return nil, opts._cdef_err or (prefix .. ': process C API unavailable')
    end
    return true
  end

  local Provider = {}

  function Provider.is_supported()
    local ok, reason = support_probe()
    return not not ok, reason
  end

  function Provider.support_reason()
    local ok, reason = support_probe()
    return ok and nil or reason
  end

  local function close_child_fds(spec, error_write)
    local keep = { [error_write] = true }
    local ordered = { error_write }
    for _, value in ipairs(spec.pass_fds or {}) do
      local fd = tonumber(value)
      if not fd or fd < 0 or fd ~= math.floor(fd) then
        return nil
      end
      if fd >= 3 and not keep[fd] then
        keep[fd] = true
        ordered[#ordered + 1] = fd
      end
      if fd >= 3 then
        local ok = set_cloexec(fd, false)
        if not ok then
          return nil
        end
      end
    end
    if spec.close_fds == false then
      return true
    end

    table.sort(ordered)
    local max_fd = tonumber_c(C.sysconf(SC_OPEN_MAX))
    if not max_fd or max_fd < 4 then
      max_fd = 1024
    end

    local function close_interval(first, last)
      if first > last then
        return true
      end
      local ok, rc = pcall(function()
        return tonumber_c(
          C.syscall(
            ffi.cast('long', SYS_close_range),
            ffi.cast('unsigned int', first),
            ffi.cast('unsigned int', last),
            ffi.cast('unsigned int', 0)
          )
        )
      end)
      if ok and rc == 0 then
        return true
      end
      local e = ok and errno() or ENOSYS
      if e ~= ENOSYS and e ~= EINVAL then
        -- Seccomp and compatibility layers may reject close_range while plain
        -- close remains available. Fall back rather than weakening close_fds.
      end
      for fd = first, last do
        if not keep[fd] then
          C.close(fd)
        end
      end
      return true
    end

    local first = 3
    for i = 1, #ordered do
      local fd = ordered[i]
      if fd >= first then
        if not close_interval(first, fd - 1) then
          return nil
        end
        first = fd + 1
      end
    end
    return close_interval(first, max_fd - 1)
  end

  local function setup_stdio_child(stdio, error_write)
    local opened_null = {}
    local function install(which, target_fd)
      local mode = stdio[which]
      if mode == 'inherit' or mode == nil then
        return true
      end
      if mode == 'stdout' and which == 'stderr' then
        if tonumber_c(C.dup2(1, 2)) == -1 then
          return nil
        end
        return true
      end
      local source
      if mode == 'pipe' then
        source = stdio[which .. '_child']
      elseif mode == 'null' then
        local flags = which == 'stdin' and O_RDONLY or O_WRONLY
        source = tonumber_c(C.open('/dev/null', flags))
        if source == -1 then
          return nil
        end
        opened_null[#opened_null + 1] = source
      end
      if source and source ~= target_fd then
        if tonumber_c(C.dup2(source, target_fd)) == -1 then
          return nil
        end
      end
      return true
    end
    if not install('stdin', 0) or not install('stdout', 1) or not install('stderr', 2) then
      return nil
    end
    for _, fd in pairs(stdio.all_fds) do
      if fd ~= 0 and fd ~= 1 and fd ~= 2 and fd ~= error_write then
        C.close(fd)
      end
    end
    for i = 1, #opened_null do
      local fd = opened_null[i]
      if fd ~= 0 and fd ~= 1 and fd ~= 2 then
        C.close(fd)
      end
    end
    return true
  end

  function Provider.start_process(host, spec)
    local ok_support, reason = support_probe()
    if not ok_support then
      return nil, nil, HostError.unsupported('host', 'process', { host = host.name, reason = reason })
    end

    local stdio = { all_fds = {} }
    local parent_fds = {}
    local function add_fd(fd)
      stdio.all_fds[#stdio.all_fds + 1] = fd
    end
    local function make_stdio(which, mode)
      stdio[which] = mode
      if mode ~= 'pipe' then
        return true
      end
      local r, w, e = raw_pipe()
      if not r then
        return nil, e
      end
      add_fd(r)
      add_fd(w)
      if which == 'stdin' then
        stdio.stdin_child = r
        parent_fds.stdin = w
      else
        parent_fds[which] = r
        stdio[which .. '_child'] = w
      end
      return true
    end

    for _, which in ipairs({ 'stdin', 'stdout', 'stderr' }) do
      local ok, e = make_stdio(which, spec[which] or 'inherit')
      if not ok then
        for _, fd in pairs(stdio.all_fds) do
          close_fd(fd)
        end
        return nil, nil, HostError.system('process', 'pipe', strerror(e), nil, e, { stream = which })
      end
    end

    local error_read, error_write, pipe_errno = raw_pipe()
    if not error_read then
      for _, fd in pairs(stdio.all_fds) do
        close_fd(fd)
      end
      return nil, nil, HostError.system('process', 'exec_pipe', strerror(pipe_errno), nil, pipe_errno)
    end

    local argv, argv_buffers = string_vector(spec.argv)
    local child_error = ffi.new('int[2]')
    local pid = tonumber_c(C.fork())
    if pid == -1 then
      local e = errno()
      close_fd(error_read)
      close_fd(error_write)
      for _, fd in pairs(stdio.all_fds) do
        close_fd(fd)
      end
      return nil, nil, HostError.system('process', 'fork', strerror(e), nil, e)
    end

    if pid == 0 then
      C.close(error_read)
      local stage = 0
      if spec.cwd and tonumber_c(C.chdir(spec.cwd)) ~= 0 then
        stage = 1
      end
      if stage == 0 and spec.new_session and tonumber_c(C.setsid()) == -1 then
        stage = 2
      end
      if
        stage == 0
        and not spec.new_session
        and spec.process_group == 'new'
        and tonumber_c(C.setpgid(0, 0)) ~= 0
      then
        stage = 3
      elseif
        stage == 0
        and not spec.new_session
        and type(spec.process_group) == 'number'
        and tonumber_c(C.setpgid(0, spec.process_group)) ~= 0
      then
        stage = 3
      end
      if stage == 0 and not setup_environment_child(spec) then
        stage = 4
      end
      if stage == 0 and not setup_stdio_child(stdio, error_write) then
        stage = 5
      end
      if stage == 0 and not close_child_fds(spec, error_write) then
        stage = 6
      end
      if stage == 0 then
        C.execvp(spec.argv[1], argv)
        stage = 7
      end
      local child_errno = errno()
      child_error[0] = stage
      child_error[1] = child_errno
      C.write(error_write, child_error, ffi.sizeof('int') * 2)
      C._exit(127)
    end

    -- Keep argv/environment buffers alive until after fork.
    local _keep = argv_buffers
    close_fd(error_write)
    for which, fd in pairs(parent_fds) do
      local child_fd = which == 'stdin' and stdio.stdin_child or stdio[which .. '_child']
      close_fd(child_fd)
    end

    local error_value = ffi.new('int[2]')
    local error_size = ffi.sizeof('int') * 2
    local total = 0
    local read_errno
    while total < error_size do
      local n, e = retry(function()
        return C.read(error_read, ffi.cast('char *', error_value) + total, error_size - total)
      end)
      if n == nil then
        read_errno = e
        break
      end
      if n == 0 then
        break
      end
      total = total + n
    end
    close_fd(error_read)
    if read_errno then
      C.kill(pid, 9)
      local status = ffi.new('int[1]')
      C.waitpid(pid, status, 0)
      for _, fd in pairs(parent_fds) do
        close_fd(fd)
      end
      return nil, nil, HostError.system('process', 'exec_handshake', strerror(read_errno), nil, read_errno)
    end
    if total > 0 then
      local stage = tonumber_c(error_value[0])
      local e = tonumber_c(error_value[1])
      local actions = {
        [1] = 'chdir',
        [2] = 'setsid',
        [3] = 'setpgid',
        [4] = 'environment',
        [5] = 'stdio',
        [6] = 'close_fds',
        [7] = 'exec',
      }
      local action = actions[stage] or 'exec_handshake'
      local status = ffi.new('int[1]')
      C.waitpid(pid, status, 0)
      for _, fd in pairs(parent_fds) do
        close_fd(fd)
      end
      if total ~= error_size then
        return nil,
          nil,
          HostError.protocol('process', 'exec_handshake', 'truncated child setup failure', {
            argv = spec.argv,
            bytes = total,
            expected = error_size,
          })
      end
      return nil,
        nil,
        HostError.system('process', action, strerror(e), nil, e, {
          argv = spec.argv,
        })
    end

    local endpoints = {}
    for which, fd in pairs(parent_fds) do
      local ok_nb, nb_errno = set_nonblocking(fd, true)
      if not ok_nb then
        for _, other in pairs(parent_fds) do
          close_fd(other)
        end
        C.kill(pid, 9)
        local status = ffi.new('int[1]')
        C.waitpid(pid, status, 0)
        return nil,
          nil,
          HostError.system('process', 'set_nonblocking', strerror(nb_errno), nil, nb_errno, {
            stream = which,
          })
      end
      local handle, wrap_err = fd_provider.wrap(fd, {
        host = host,
        name = (spec.name or ('process-' .. tostring(pid))) .. ':' .. which,
        nonblocking = false,
        cloexec = true,
      })
      if not handle then
        for _, endpoint in pairs(endpoints) do
          endpoint:close('process endpoint wrap failed')
        end
        for other_which, other_fd in pairs(parent_fds) do
          if other_which ~= which and not endpoints[other_which] then
            close_fd(other_fd)
          end
        end
        C.kill(pid, 9)
        local status = ffi.new('int[1]')
        C.waitpid(pid, status, 0)
        return nil, nil, wrap_err
      end
      if which == 'stdin' then
        handle.capabilities.read = false
        handle.capabilities.shutdown_read = false
      else
        handle.capabilities.write = false
        handle.capabilities.shutdown_write = false
      end
      endpoints[which] = handle
    end

    local pidfd
    local pidfd_fd = pidfd_open(pid)
    if pidfd_fd then
      pidfd = fd_provider.wrap(pidfd_fd, {
        host = host,
        name = (spec.name or ('process-' .. tostring(pid))) .. ':pidfd',
        nonblocking = true,
        cloexec = true,
      })
      if pidfd then
        pidfd.capabilities.read = false
        pidfd.capabilities.write = false
      else
        close_fd(pidfd_fd)
      end
    end

    local process = setmetatable({
      name = spec.name or ('process-' .. tostring(pid)),
      _pid = pid,
      group_id = (spec.new_session or spec.process_group == 'new') and pid
        or (type(spec.process_group) == 'number' and spec.process_group or nil),
      pidfd = pidfd,
      poll_interval = spec.poll_interval or 0.025,
      status = nil,
      reaped = false,
      closed = false,
    }, HostProcess)
    IOAudit.created(process, { kind = 'process_handle' })
    if pidfd then
      IOAudit.transfer(pidfd, process, { kind = 'host_handle', role = 'pidfd' })
    end
    return process, endpoints
  end

  return Provider
end

Common.unsupported = unsupported
return Common
