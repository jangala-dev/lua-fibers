-- Linux/POSIX child-process provider shared by LuaJIT FFI and cffi hosts.
--
-- The provider owns the fork/exec handshake, pipe creation, pid identity and
-- exactly-once waitpid call. The higher Process facility owns policy, Streams,
-- shutdown escalation and structural settlement.

local HostError = require('fibers.host.error')
local IOAudit = require('fibers.internal.io_audit')
local ProcessCore = require('fibers.host.process_core')
local ProcessIO = require('fibers.host.process_io_core')
local FfiNative = require('fibers.host.ffi_native')

local Common = {}

function Common.new(opts)
  opts = opts or {}
  local native = opts.native or FfiNative.new(opts)
  local ffi, C, tonumber_c = native.ffi, native.C, native.number
  local fd_provider = assert(opts.fd, 'fd provider required')
  local prefix = opts.error_prefix or 'fibers.host.process_ffi'

  local ok_cdef, cdef_err = native.cdef([[
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
  if not ok_cdef then
    opts._cdef_err = cdef_err
  end

  local EINTR = 4
  local EINVAL = 22
  local ENOSYS = 38
  local O_RDONLY = 0
  local O_WRONLY = 1
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

  local errno = native.errno
  local strerror = native.strerror
  local retry = native.retry

  local set_cloexec = native.set_cloexec
  local set_nonblocking = native.set_nonblocking
  local close_fd = native.close_fd
  local function raw_pipe()
    return native.pipe(true)
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

  local signals = ProcessCore.signals(SIG_NUMBERS)

  local function decode_status(raw)
    local low = raw % 256
    local signal = low % 128
    if signal == 0 then
      return ProcessCore.exited(math.floor(raw / 256) % 256)
    end
    if signal ~= 127 then
      return ProcessCore.signalled(signals, signal, low >= 128)
    end
  end

  local function wait_process(self)
    if self.status then
      return require('fibers.op').always(true)
    end
    if self.pidfd then
      return self.pidfd:read_ready_op()
    end
    return require('fibers.sleep').sleep_op(self.poll_interval)
  end

  local function reap_process(self)
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
    self.status, self.reaped = decoded, true
    return decoded
  end

  local function signal_process(self, number, target)
    local pid = target == 'group' and -math.abs(self.group_id or self._pid) or self._pid
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

  local function close_process(self, reason)
    if self.pidfd then
      self.pidfd:close(reason)
      self.pidfd = nil
    end
    return true
  end

  local HostProcess = ProcessCore.class({
    signals = signals,
    bind = function(self, rt)
      if self.pidfd and type(self.pidfd.bind_runtime) == 'function' then
        self.pidfd:bind_runtime(rt)
      end
    end,
    wait = wait_process,
    reap = reap_process,
    signal = signal_process,
    close = close_process,
  })

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
    return ProcessIO.install_child(stdio, {
      targets = { stdin = 0, stdout = 1, stderr = 2 },
      stdout = 1,
      same = function(a, b)
        return a == b
      end,
      duplicate = function(source, target)
        if tonumber_c(C.dup2(source, target)) == -1 then
          return nil
        end
        return true
      end,
      open_null = function(which)
        local fd = tonumber_c(C.open('/dev/null', which == 'stdin' and O_RDONLY or O_WRONLY))
        return fd == -1 and nil or fd
      end,
      keep = function(fd)
        return fd == 0 or fd == 1 or fd == 2 or fd == error_write
      end,
      close = function(fd)
        C.close(fd)
      end,
    })
  end

  function Provider.start_process(host, spec)
    local ok_support, reason = support_probe()
    if not ok_support then
      return nil, nil, HostError.unsupported('host', 'process', { host = host.name, reason = reason })
    end

    local stdio, parent_fds, stdio_errno = ProcessIO.open(spec, function()
      local r, w, e = raw_pipe()
      if not r then
        return nil, nil, e
      end
      return r, w
    end, close_fd)
    if not stdio then
      return nil, nil, HostError.system('process', 'pipe', strerror(stdio_errno), nil, stdio_errno)
    end

    local error_read, error_write, pipe_errno = raw_pipe()
    if not error_read then
      for _, fd in pairs(stdio.all) do
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
      for _, fd in pairs(stdio.all) do
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
    ProcessIO.close_child_ends(stdio, parent_fds, close_fd)

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

    local endpoints, wrap_err = ProcessIO.wrap({
      host = host,
      name = spec.name,
      pid = pid,
      parents = parent_fds,
      wrap = function(fd, wrap_opts)
        local ok_nb, nb_errno = set_nonblocking(fd, true)
        if not ok_nb then
          return nil, HostError.system('process', 'set_nonblocking', strerror(nb_errno), nil, nb_errno)
        end
        wrap_opts.nonblocking = false
        return fd_provider.new(fd, wrap_opts)
      end,
      close_raw = close_fd,
      cloexec = true,
      abort = function()
        C.kill(pid, 9)
        local status = ffi.new('int[1]')
        C.waitpid(pid, status, 0)
      end,
    })
    if not endpoints then
      return nil, nil, wrap_err
    end

    local pidfd
    local pidfd_fd = pidfd_open(pid)
    if pidfd_fd then
      pidfd = fd_provider.new(pidfd_fd, {
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

return Common
