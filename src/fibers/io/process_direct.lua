-- Shared close-on-exec fork/exec strategy.
--
-- The native binding supplies raw POSIX mechanisms.  This module owns the
-- launch protocol, stdio plan, Process object, errors and exactly-once reaping.

local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Process = require('fibers.io.process')
local Op = require('fibers.op')
local HostOffer = require('fibers.io.offer')

local Direct = {}

local ACTION = {
  cwd = 'chdir',
  session = 'setsid',
  group = 'setpgid',
  environment = 'environment',
  stdio = 'stdio',
  close_fds = 'close_fds',
  exec = 'exec',
}

local function error_value(spec, action, errno, message, fields)
  return IOError.system(
    'process',
    action,
    message or spec.message(errno) or (action .. ' failed'),
    spec.name_of and spec.name_of(errno),
    errno,
    fields
  )
end

function Direct.new(spec)
  local Core, IO = Process.core, Process.io
  local signals = Core.signals(spec.signals)

  local function close(value)
    if value ~= nil then
      pcall(spec.close, value)
    end
  end

  local function write_all(value, bytes)
    local offset = 0
    while offset < #bytes do
      local count, errno, message = spec.write(value, bytes:sub(offset + 1))
      if count then
        offset = offset + count
      elseif not spec.interrupted(errno) then
        return nil, errno, message
      end
    end
    return true
  end

  local function child_fail(error_write, stage, errno)
    write_all(error_write, tostring(stage) .. ':' .. tostring(errno or 0) .. '\n')
    spec.exit(127)
  end

  local function read_handshake(value)
    local buffer = ''
    while true do
      local chunk, errno, message = spec.read(value, 256)
      if chunk ~= nil then
        if chunk == '' then
          return buffer
        end
        buffer = buffer .. chunk
        if #buffer > 4096 then
          return nil, nil, 'child setup response is too large'
        end
      elseif not spec.interrupted(errno) then
        return nil, errno, message
      end
    end
  end

  local function wait_blocking(pid)
    while true do
      local result, errno, message = spec.wait(pid, false)
      if result then
        return result
      end
      if not spec.interrupted(errno) then
        return nil, errno, message
      end
    end
  end

  local function kill_and_reap(pid)
    pcall(spec.kill, pid, signals.numbers.kill)
    wait_blocking(pid)
  end

  local function reap_process(self)
    if self.status then
      return self.status
    end
    local result, errno, message = spec.wait(self._pid, true)
    if not result then
      if spec.again(errno) then
        return nil, IOError.would_block('process', 'reap', { pid = self._pid })
      end
      return nil, error_value(spec, 'reap', errno, message, { pid = self._pid })
    end
    if result.kind == 'running' or result.kind == 'stopped' then
      return nil, IOError.would_block('process', 'reap', { pid = self._pid })
    end
    local status
    if result.kind == 'exited' then
      status = Core.exited(result.code)
    elseif result.kind == 'signalled' then
      status = Core.signalled(signals, result.signal, result.core_dumped)
    else
      return nil,
        IOError.protocol('process', 'reap', 'unexpected wait status', { pid = self._pid, status = result })
    end
    self.status, self.reaped = status, true
    return status
  end

  local function signal_process(self, number, target)
    local destination = target == 'group' and -math.abs(self.group_id or self._pid) or self._pid
    local ok, errno, message = spec.kill(destination, number)
    if not ok then
      return nil,
        error_value(spec, 'signal', errno, message, { pid = self._pid, signal = number, target = target })
    end
    return true
  end

  local ProcessClass = Core.class({
    signals = signals,
    open_exit = function(self, scope)
      if not self.exit_source then
        self.exit_source = HostOffer.new({
          name = self.name .. ':exit',
          domain = 'process',
          action = 'reap',
          role = 'process_exit_completion',
          one_shot = true,
          capacity = 1,
          handle = self.pidfd,
          mode = self.pidfd and 'read' or 'poll',
          poll_interval = self.poll_interval,
          pull = function()
            return reap_process(self)
          end,
        })
      end
      return self.exit_source:open_op(scope)
    end,
    exit = function(self)
      if self.reaped and self.status then
        return Op.always(self.status)
      end
      if not self.exit_source then
        return Op.always(
          nil,
          IOError.protocol('process', 'exit', 'process exit source is not open', { pid = self._pid })
        )
      end
      return self.exit_source:result_op()
    end,
    signal = signal_process,
    close = function(self, reason)
      if self.pidfd then
        self.pidfd:close(reason or 'process closed')
        self.pidfd = nil
      end
      return true
    end,
  })

  local Provider = {}
  function Provider.is_supported()
    return spec.supported()
  end
  function Provider.support_reason()
    local ok, reason = spec.supported()
    return ok and nil or reason
  end

  function Provider.start_process(host, process_spec)
    local supported, reason = spec.supported()
    if not supported then
      return nil, nil, IOError.unsupported('host', 'process', { host = host.name, reason = reason })
    end

    local stdio, parents, stdio_err = IO.open(process_spec, function(which)
      local reader, writer, errno, message = spec.pipe()
      if not reader then
        return nil, nil, error_value(spec, 'pipe', errno, message, { stream = which })
      end
      return reader, writer
    end, close)
    if not stdio then
      return nil, nil, stdio_err
    end

    local error_read, error_write, pipe_errno, pipe_message = spec.pipe()
    if not error_read then
      for i = 1, #stdio.all do
        close(stdio.all[i])
      end
      return nil, nil, error_value(spec, 'exec_pipe', pipe_errno, pipe_message)
    end
    local cloexec, cloexec_errno, cloexec_message = spec.set_cloexec(error_write, true)
    if not cloexec then
      close(error_read)
      close(error_write)
      for i = 1, #stdio.all do
        close(stdio.all[i])
      end
      return nil, nil, error_value(spec, 'exec_pipe', cloexec_errno, cloexec_message)
    end

    local pid, fork_errno, fork_message = spec.fork()
    if not pid then
      close(error_read)
      close(error_write)
      for i = 1, #stdio.all do
        close(stdio.all[i])
      end
      return nil, nil, error_value(spec, 'fork', fork_errno, fork_message)
    end

    if pid == 0 then
      close(error_read)
      if process_spec.cwd then
        local ok, errno = spec.chdir(process_spec.cwd)
        if not ok then
          child_fail(error_write, 'cwd', errno)
        end
      end
      if process_spec.new_session then
        local ok, errno = spec.setsid()
        if not ok then
          child_fail(error_write, 'session', errno)
        end
      elseif process_spec.process_group == 'new' then
        local ok, errno = spec.setpgid(0, 0)
        if not ok then
          child_fail(error_write, 'group', errno)
        end
      elseif type(process_spec.process_group) == 'number' then
        local ok, errno = spec.setpgid(0, process_spec.process_group)
        if not ok then
          child_fail(error_write, 'group', errno)
        end
      end
      local env_ok, env_errno = spec.environment(process_spec)
      if not env_ok then
        child_fail(error_write, 'environment', env_errno)
      end
      local stdio_ok, stdio_errno = IO.install_child(stdio, {
        targets = spec.stdio.targets,
        stdout = spec.stdio.stdout,
        same = spec.stdio.same,
        duplicate = function(source, target)
          local ok, errno = spec.stdio.duplicate(source, target)
          return ok, nil, errno
        end,
        open_null = function(which)
          local value, errno = spec.stdio.open_null(which)
          return value, nil, errno
        end,
        keep = function(value)
          return spec.stdio.keep(value, error_write)
        end,
        close = close,
      })
      if not stdio_ok then
        child_fail(error_write, 'stdio', stdio_errno)
      end
      local close_ok, close_errno = spec.close_inherited(process_spec, error_write)
      if not close_ok then
        child_fail(error_write, 'close_fds', close_errno)
      end
      local _, exec_errno = spec.exec(process_spec.argv)
      child_fail(error_write, 'exec', exec_errno)
    end

    close(error_write)
    IO.close_child_ends(stdio, parents, close)
    local handshake, read_errno, read_message = read_handshake(error_read)
    close(error_read)
    if handshake == nil then
      kill_and_reap(pid)
      for _, value in pairs(parents) do
        close(value)
      end
      return nil, nil, error_value(spec, 'exec_handshake', read_errno, read_message)
    end
    if handshake ~= '' then
      wait_blocking(pid)
      for _, value in pairs(parents) do
        close(value)
      end
      local stage, number = handshake:match('^([%w_]+):(%d+)\n?$')
      if not stage then
        return nil,
          nil,
          IOError.protocol(
            'process',
            'exec_handshake',
            'invalid child setup failure',
            { argv = process_spec.argv, payload = handshake }
          )
      end
      local errno = tonumber(number)
      local action = ACTION[stage] or 'exec_handshake'
      return nil, nil, error_value(spec, action, errno, nil, { argv = process_spec.argv })
    end

    local endpoints, wrap_err = IO.wrap({
      host = host,
      name = process_spec.name,
      pid = pid,
      parents = parents,
      wrap = spec.Fd.new,
      close_raw = close,
      cloexec = true,
      abort = function()
        kill_and_reap(pid)
      end,
    })
    if not endpoints then
      return nil, nil, wrap_err
    end

    local pidfd
    if spec.pidfd then
      local raw = spec.pidfd(pid)
      if raw then
        pidfd = spec.Fd.new(raw, {
          host = host,
          name = (process_spec.name or ('process-' .. pid)) .. ':pidfd',
          nonblocking = true,
          cloexec = true,
        })
        if pidfd then
          pidfd.capabilities.write = false
          pidfd.capabilities.shutdown_write = false
        end
      end
    end

    local process = setmetatable({
      name = process_spec.name or ('process-' .. tostring(pid)),
      _pid = pid,
      pidfd = pidfd,
      group_id = (process_spec.new_session or process_spec.process_group == 'new') and pid
        or (type(process_spec.process_group) == 'number' and process_spec.process_group or nil),
      poll_interval = process_spec.poll_interval or 0.025,
      status = nil,
      reaped = false,
      closed = false,
    }, ProcessClass)
    IOAudit.created(process, { kind = 'process_handle' })
    if pidfd then
      IOAudit.transfer(pidfd, process, { kind = 'host_handle', role = 'pidfd' })
    end
    return process, endpoints
  end

  return Provider
end

return Direct
