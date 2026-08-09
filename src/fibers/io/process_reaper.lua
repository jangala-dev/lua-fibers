-- Shared reaper-process launch strategy for bindings without close-on-exec.
--
-- A helper owns the real child, reports launch and terminal status through one
-- pipe, and reaps it exactly once.  Providers supply opaque-handle mechanics.

local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Process = require('fibers.io.process')

local Reaper = {}
local ACTION =
  { cwd = 'chdir', session = 'setsid', stdio = 'stdio', pipe = 'pipe', fork = 'fork', exec = 'exec' }

function Reaper.new(spec)
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
      local count, errno, message = spec.write(value, bytes, offset)
      if type(count) == 'number' then
        if count <= 0 then
          return nil, errno, message or 'short write'
        end
        offset = offset + count
      elseif count == true then
        return true
      elseif not spec.interrupted(errno) then
        return nil, errno, message
      end
    end
    return true
  end

  local function read_chunk(value, maximum)
    local data, errno, message = spec.read(value, maximum)
    if type(data) == 'string' then
      return data
    end
    if spec.no_error(errno, message) then
      return ''
    end
    if spec.again(errno) then
      return nil, 'would_block', errno
    end
    return nil, message, errno
  end

  local function environment(process_spec)
    local out = {}
    if process_spec.env_mode ~= 'replace' then
      local current, errno, message = spec.environment()
      if not current then
        return nil,
          IOError.system(
            'process',
            'environment',
            message or spec.message(errno),
            spec.name_of(errno),
            errno
          )
      end
      for name, value in pairs(current) do
        out[tostring(name)] = tostring(value)
      end
    end
    for _, name in ipairs(process_spec.unset_env or {}) do
      out[tostring(name)] = nil
    end
    for name, value in pairs(process_spec.env or {}) do
      out[tostring(name)] = tostring(value)
    end
    return out
  end

  local function absolute_base(cwd)
    if cwd and cwd:sub(1, 1) == '/' then
      return cwd
    end
    local here = spec.getcwd and spec.getcwd() or '.'
    if type(here) ~= 'string' then
      here = '.'
    end
    return cwd and cwd ~= '' and (here .. '/' .. cwd) or here
  end

  local function preflight(process_spec, env)
    if type(process_spec.process_group) == 'number' then
      return nil,
        IOError.unsupported(
          'process',
          'process_group',
          { host = spec.name, process_group = process_spec.process_group }
        )
    end
    if process_spec.pass_fds and #process_spec.pass_fds > 0 then
      return nil, IOError.unsupported('process', 'pass_fds', { host = spec.name })
    end
    if process_spec.cwd then
      local kind, errno, message = spec.stat(process_spec.cwd)
      if kind ~= 'dir' then
        return nil,
          IOError.system(
            'process',
            'chdir',
            message or spec.message(errno),
            spec.name_of(errno),
            errno,
            { cwd = process_spec.cwd }
          )
      end
    end
    local program = tostring(process_spec.argv[1])
    local function executable(path)
      local ok = spec.access(path)
      return ok and path or nil
    end
    if program:find('/', 1, true) then
      local candidate = program:sub(1, 1) == '/' and program
        or (absolute_base(process_spec.cwd) .. '/' .. program)
      if executable(candidate) then
        return candidate
      end
    else
      local base = absolute_base(process_spec.cwd)
      for part in ((env.PATH or '/bin:/usr/bin') .. ':'):gmatch('(.-):') do
        local dir = part == '' and base or part
        if dir:sub(1, 1) ~= '/' then
          dir = base .. '/' .. dir
        end
        local candidate = dir .. '/' .. program
        if executable(candidate) then
          return candidate
        end
      end
    end
    return nil,
      IOError.system(
        'process',
        'exec',
        'executable not found: ' .. program,
        'ENOENT',
        spec.enoent,
        { argv = process_spec.argv }
      )
  end

  local function make_pipe(action, fields)
    local reader, writer, errno, message = spec.pipe()
    if reader and writer then
      return reader, writer
    end
    return nil,
      nil,
      IOError.system(
        'process',
        action or 'pipe',
        message or spec.message(errno),
        spec.name_of(errno),
        errno,
        fields
      )
  end

  local function child_fail(writer, stage, errno)
    write_all(writer, 'failed ' .. tostring(stage) .. ' ' .. tostring(errno or 0) .. '\n')
    close(writer)
    spec.exit(127)
  end

  local function child_stdio(stdio)
    return IO.install_child(stdio, {
      targets = spec.stdio.targets,
      stdout = spec.stdio.stdout,
      same = spec.stdio.same,
      duplicate = function(source, target)
        local ok, errno, message = spec.stdio.duplicate(source, target)
        return ok, message, errno
      end,
      open_null = function(which)
        local value, errno, message = spec.stdio.open_null(which)
        return value, message, errno
      end,
      keep = function()
        return false
      end,
      close = close,
    })
  end

  local function close_inherited(values)
    for _, value in ipairs(values or {}) do
      local number = spec.number(value)
      if not number or number > 2 then
        close(value)
      end
    end
  end

  local function reaper_main(process_spec, executable, env, stdio, inherited, status_read, status_write)
    close(status_read)
    close_inherited(inherited)
    local launch_read, launch_write = spec.pipe()
    if not launch_read then
      write_all(status_write, 'failed pipe 0\n')
      close(status_write)
      spec.exit(127)
    end
    local child, errno = spec.fork()
    if not child then
      write_all(status_write, 'failed fork ' .. tostring(errno or 0) .. '\n')
      close(launch_read)
      close(launch_write)
      close(status_write)
      spec.exit(127)
    end
    if child == 0 then
      close(launch_read)
      close(status_write)
      if process_spec.cwd then
        local ok, number = spec.chdir(process_spec.cwd)
        if not ok then
          child_fail(launch_write, 'cwd', number)
        end
      end
      if process_spec.process_group == 'new' then
        local ok, number = spec.setsid()
        if not ok then
          child_fail(launch_write, 'session', number)
        end
      end
      local ok, _, number = child_stdio(stdio)
      if not ok then
        child_fail(launch_write, 'stdio', number)
      end
      write_all(launch_write, 'ready\n')
      close(launch_write)
      spec.exec(executable, process_spec.argv, env)
      spec.exit(127)
    end

    close(launch_write)
    IO.close_all(stdio.all, close)
    local line = ''
    while not line:find('\n', 1, true) do
      local chunk = read_chunk(launch_read, 256)
      if not chunk or chunk == '' then
        break
      end
      line = line .. chunk
    end
    close(launch_read)
    if line ~= 'ready\n' then
      spec.kill(child, signals.numbers.kill)
      Core.wait(spec, child, false)
      write_all(status_write, line ~= '' and line or 'failed exec 0\n')
      close(status_write)
      spec.exit(127)
    end

    write_all(status_write, 'pid ' .. tostring(child) .. '\n')
    local result = Core.wait(spec, child, false)
    if result and result.kind == 'exited' then
      write_all(status_write, 'exited ' .. tostring(result.code or 0) .. '\n')
    elseif result and result.kind == 'signalled' then
      write_all(status_write, 'signalled ' .. tostring(result.signal or 0) .. '\n')
    else
      write_all(status_write, 'failed reap 0\n')
    end
    close(status_write)
    spec.exit(0)
  end

  local function parse_startup(line, process_spec)
    local pid = line:match('^pid (%d+)$')
    if pid then
      return tonumber(pid)
    end
    local stage, number = line:match('^failed ([%w_]+) (%d+)$')
    if stage then
      local errno = tonumber(number)
      local action = ACTION[stage] or stage
      return nil,
        IOError.system(
          'process',
          action,
          spec.message(errno) or (action .. ' failed'),
          spec.name_of(errno),
          errno,
          { argv = process_spec.argv }
        )
    end
    return nil,
      IOError.protocol(
        'process',
        'exec_handshake',
        'invalid reaper startup response',
        { argv = process_spec.argv, payload = line }
      )
  end

  local function read_startup(status_read, process_spec)
    local buffer = ''
    while true do
      local line, rest = buffer:match('^([^\n]*)\n(.*)$')
      if line then
        local pid, err = parse_startup(line, process_spec)
        return pid, rest, err
      end
      local chunk, err = read_chunk(status_read, 256)
      if not chunk then
        return nil, nil, IOError.system('process', 'exec_handshake', tostring(err), nil, nil)
      end
      if chunk == '' then
        return nil,
          nil,
          IOError.protocol(
            'process',
            'exec_handshake',
            'reaper closed before reporting a child pid',
            { argv = process_spec.argv }
          )
      end
      buffer = buffer .. chunk
      if #buffer > 4096 then
        return nil,
          nil,
          IOError.protocol(
            'process',
            'exec_handshake',
            'reaper response is too large',
            { argv = process_spec.argv }
          )
      end
    end
  end

  local function parse_terminal(self)
    local line, rest = self.buffer:match('^([^\n]*)\n(.*)$')
    if not line then
      return
    end
    self.buffer = rest
    local code = line:match('^exited (%d+)$')
    if code then
      self.status = Core.exited(tonumber(code))
      return
    end
    local number = line:match('^signalled (%d+)$')
    if number then
      self.status = Core.signalled(signals, tonumber(number))
      return
    end
    local stage, errno = line:match('^failed ([%w_]+) (%d+)$')
    if stage then
      self.terminal_error = IOError.system(
        'process',
        ACTION[stage] or stage,
        spec.message(tonumber(errno)),
        spec.name_of(tonumber(errno)),
        tonumber(errno),
        { pid = self._pid }
      )
      return
    end
    self.terminal_error = IOError.protocol(
      'process',
      'reap',
      'invalid reaper terminal response',
      { pid = self._pid, payload = line }
    )
  end

  local function reap_process(self)
    if self.reaped then
      return self.status
    end
    parse_terminal(self)
    while not self.status and not self.terminal_error do
      local chunk, err = self.status_handle:read(spec.buffer_size)
      if chunk then
        self.buffer = self.buffer .. chunk
        parse_terminal(self)
      elseif IOError.is_would_block(err) then
        return nil, err
      elseif IOError.is_eof(err) then
        self.terminal_error =
          IOError.protocol('process', 'reap', 'reaper closed without terminal status', { pid = self._pid })
      else
        return nil, IOError.normalise(err, { domain = 'process', action = 'reap', pid = self._pid })
      end
    end
    local result, errno, message = spec.wait(self.reaper_pid, true)
    if not result or result.kind == 'running' then
      return nil, IOError.would_block('process', 'reap', { pid = self._pid, reaper_pid = self.reaper_pid })
    end
    if self.status_handle then
      self.status_handle:close('process reaped')
      self.status_handle = nil
    end
    if self.terminal_error then
      return nil, self.terminal_error
    end
    self.reaped = true
    return self.status
  end

  local ProcessClass = Core.class({
    signals = signals,
    bind = function(self, rt)
      if self.status_handle then
        self.status_handle:bind_runtime(rt)
      end
    end,
    reap = reap_process,
    exit_handle = function(self) return self.status_handle end,
    kill = spec.kill, message = spec.message, name_of = spec.name_of,
    close = function(self, reason)
      if self.status_handle then
        self.status_handle:close(reason or 'process closed')
        self.status_handle = nil
      end
      if not self.reaped then
        pcall(spec.wait, self.reaper_pid, true)
      end
      return true
    end,
  })

  local Provider = Core.provider(spec)

  function Provider.start_process(host, process_spec)
    local ok, reason = spec.supported()
    if not ok then
      return nil, nil, IOError.unsupported('host', 'process', { host = host.name, reason = reason })
    end
    local env, env_err = environment(process_spec)
    if not env then
      return nil, nil, env_err
    end
    local executable, exec_err = preflight(process_spec, env)
    if not executable then
      return nil, nil, exec_err
    end
    local inherited = process_spec.close_fds == false and {} or spec.open_objects()
    local stdio, parents, stdio_err = IO.open(process_spec, function(which)
      return make_pipe('pipe', { stream = which })
    end, close)
    if not stdio then
      return nil, nil, stdio_err
    end
    local status_read, status_write, status_err = make_pipe('status_pipe')
    if not status_read then
      IO.close_all(stdio.all, close)
      return nil, nil, status_err
    end
    local blocking, errno, message = spec.set_blocking(status_read, true)
    if not blocking then
      return nil,
        nil,
        IOError.system(
          'process',
          'exec_handshake',
          message or spec.message(errno),
          spec.name_of(errno),
          errno
        )
    end
    local reaper, fork_errno, fork_message = spec.fork()
    if not reaper then
      return nil,
        nil,
        IOError.system(
          'process',
          'fork',
          fork_message or spec.message(fork_errno),
          spec.name_of(fork_errno),
          fork_errno
        )
    end
    if reaper == 0 then
      reaper_main(process_spec, executable, env, stdio, inherited, status_read, status_write)
      spec.exit(127)
    end
    IO.close_child_ends(stdio, parents, close)
    close(status_write)
    local pid, buffer, startup_err = read_startup(status_read, process_spec)
    if not pid then
      close(status_read)
      IO.close_all(parents, close)
      Core.wait(spec, reaper, false)
      return nil, nil, startup_err
    end
    local status_handle, wrap_err = spec.Fd.new(
      status_read,
      {
        host = host, label = (process_spec.label or ('process-' .. pid)) .. ':status',
        nonblocking = true, readable = true, writable = false,
      }
    )
    if not status_handle then
      return nil, nil, IOError.normalise(wrap_err, { domain = 'process', action = 'wrap_status' })
    end
    local endpoints, endpoint_err = IO.wrap({
      host = host,
      label = process_spec.label,
      pid = pid,
      parents = parents,
      wrap = spec.Fd.new,
      close_raw = close,
    })
    if not endpoints then
      status_handle:close()
      return nil, nil, endpoint_err
    end
    local process = Core.handle(ProcessClass, pid, process_spec, {
      reaper_pid = reaper,
      group_id = process_spec.process_group == 'new' and pid or nil,
      status_handle = status_handle,
      buffer = buffer or '',
    })
    IOAudit.transfer(status_handle, process, { kind = 'host_handle', role = 'process_status' })
    return process, endpoints
  end

  Provider._test = {
    preflight = preflight,
    environment = environment,
    parse_startup = parse_startup,
    read_chunk = read_chunk,
    close_inherited = close_inherited,
  }
  return Provider
end

return Reaper
