-- Shared process status, lifecycle and stdio machinery.

local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')

local M = {}

local function close_returned(value, reason)
  if value and type(value.close) == 'function' then
    pcall(value.close, value, reason)
  end
end

local function invalid_contract(host, missing)
  return IOError.protocol(
    'host',
    'start_process',
    'host process provider returned an invalid process handle',
    {
      host = host and host.name or nil,
      missing = missing,
    }
  )
end

-- One host-independent launch boundary. Direct waitpid providers, reaper-process
-- providers, simulated hosts and future platform implementations all return the
-- same process-handle contract beneath the public Process Lifetime.
function M.start(host, spec)
  if not host or type(host.start_process) ~= 'function' then
    return nil, nil, IOError.unsupported('host', 'process', { host = host and host.name or nil })
  end
  local process, endpoints, err = host:start_process(spec)
  if not process then
    return nil, nil, err or endpoints
  end
  if endpoints ~= nil and type(endpoints) ~= 'table' then
    close_returned(process, 'invalid host process contract')
    return nil, nil, invalid_contract(host, 'endpoints')
  end

  local required = { 'open_exit_op', 'exit_op', 'signal', 'close' }
  for i = 1, #required do
    local name = required[i]
    if type(process[name]) ~= 'function' then
      close_returned(process, 'invalid host process contract')
      for _, endpoint in pairs(endpoints or {}) do
        close_returned(endpoint, 'invalid host process contract')
      end
      return nil, nil, invalid_contract(host, name)
    end
  end
  local pid = type(process.pid) == 'function' and process:pid() or process.pid or process._pid
  if pid == nil then
    close_returned(process, 'invalid host process contract')
    for _, endpoint in pairs(endpoints or {}) do
      close_returned(endpoint, 'invalid host process contract')
    end
    return nil, nil, invalid_contract(host, 'pid')
  end
  return process, endpoints or {}
end

local Process = {}
do
  local M = Process

  local DEFAULT_SIGNALS = {
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
  local DISPLAY = { hup = 'HUP', int = 'INT', quit = 'QUIT', kill = 'KILL', term = 'TERM' }

  function M.signals(overrides)
    local numbers, names = {}, {}
    for key, fallback in pairs(DEFAULT_SIGNALS) do
      local number = overrides and overrides[key] or fallback
      numbers[key] = number
      if DISPLAY[key] then
        names[number] = DISPLAY[key]
      end
    end
    return {
      numbers = numbers,
      name = function(number)
        return names[number]
      end,
      normalise = function(value)
        if type(value) == 'number' and value > 0 and value == math.floor(value) then
          return value
        end
        if type(value) == 'string' then
          local number = numbers[value:lower():gsub('^sig', '')]
          if number then
            return number
          end
        end
        return nil, IOError.invalid_argument('process', 'signal', { signal = value })
      end,
    }
  end

  function M.exited(code)
    code = tonumber(code) or 0
    return { kind = 'exited', code = code, success = code == 0 }
  end

  function M.signalled(signals, number, core_dumped)
    number = tonumber(number) or 0
    return {
      kind = 'signalled',
      signal = number,
      signal_name = signals.name(number),
      core_dumped = core_dumped == true,
      success = false,
    }
  end

  function M.class(spec)
    local open_exit = assert(spec.open_exit, 'process class requires open_exit')
    local exit = assert(spec.exit, 'process class requires exit')
    local Process = {}
    Process.__index = Process

    function Process:bind_runtime(rt)
      self.runtime = rt
      IOAudit.bind(self, rt)
      if spec.bind then
        spec.bind(self, rt)
      end
      return self
    end

    function Process:pid()
      return self._pid
    end

    function Process:open_exit_op(scope)
      return open_exit(self, scope)
    end

    function Process:exit_op()
      return exit(self)
    end

    function Process:signal(value, target)
      if self.reaped then
        return nil, IOError.closed('process', 'signal', { pid = self._pid })
      end
      local number, err = spec.signals.normalise(value)
      if not number then
        return nil, err
      end
      return spec.signal(self, number, target)
    end

    function Process:close(reason)
      if self.closed then
        IOAudit.closing(self, reason)
        IOAudit.closed(self, true, nil, reason)
        return true
      end
      self.closed = true
      IOAudit.closing(self, reason)
      local ok, err = true, nil
      if spec.close then
        ok, err = spec.close(self, reason)
      end
      IOAudit.closed(self, ok ~= nil and ok ~= false, err, reason)
      return ok, err
    end

    return Process
  end
end
M.core = Process

local ProcessIO = {}
do
  local M = ProcessIO
  local STREAMS = { 'stdin', 'stdout', 'stderr' }

  function M.open(spec, open_pipe, close_raw)
    local stdio = { all = {} }
    local parents = {}
    for i = 1, #STREAMS do
      local which = STREAMS[i]
      local mode = spec[which] or 'inherit'
      stdio[which] = mode
      if mode == 'pipe' then
        local reader, writer, err, extra = open_pipe(which)
        if not reader then
          for j = 1, #stdio.all do
            close_raw(stdio.all[j])
          end
          return nil, nil, err, extra
        end
        stdio.all[#stdio.all + 1] = reader
        stdio.all[#stdio.all + 1] = writer
        if which == 'stdin' then
          stdio.stdin_child, parents.stdin = reader, writer
        else
          stdio[which .. '_child'], parents[which] = writer, reader
        end
      end
    end
    return stdio, parents
  end

  function M.close_child_ends(stdio, parents, close_raw)
    for which in pairs(parents or {}) do
      close_raw(which == 'stdin' and stdio.stdin_child or stdio[which .. '_child'])
    end
  end

  function M.install_child(stdio, ops)
    local opened = {}
    local function install(which, target)
      local mode = stdio[which]
      if mode == nil or mode == 'inherit' then
        return true
      end
      if which == 'stderr' and mode == 'stdout' then
        return ops.duplicate(ops.stdout, target)
      end
      local source
      if mode == 'pipe' then
        source = stdio[which .. '_child']
      elseif mode == 'null' then
        local err, extra
        source, err, extra = ops.open_null(which)
        if source == nil then
          return nil, err, extra
        end
        opened[#opened + 1] = source
      end
      if source ~= nil and not ops.same(source, target) then
        local ok, err, extra = ops.duplicate(source, target)
        if not ok then
          return nil, err, extra
        end
      end
      return true
    end
    for i = 1, #STREAMS do
      local which = STREAMS[i]
      local ok, err, extra = install(which, ops.targets[which])
      if not ok then
        return nil, err, extra
      end
    end
    for i = 1, #stdio.all do
      local value = stdio.all[i]
      if not ops.keep(value) then
        ops.close(value)
      end
    end
    for i = 1, #opened do
      local value = opened[i]
      if not ops.keep(value) then
        ops.close(value)
      end
    end
    return true
  end

  local function restrict(handle, which)
    if which == 'stdin' then
      handle.capabilities.read = false
      handle.capabilities.shutdown_read = false
    else
      handle.capabilities.write = false
      handle.capabilities.shutdown_write = false
    end
  end

  function M.wrap(opts)
    local endpoints = {}
    local parents = opts.parents or {}
    for which, raw in pairs(parents) do
      local handle, err = opts.wrap(raw, {
        host = opts.host,
        name = (opts.name or ('process-' .. tostring(opts.pid))) .. ':' .. which,
        nonblocking = opts.nonblocking ~= false,
        cloexec = opts.cloexec,
      })
      if not handle then
        for _, endpoint in pairs(endpoints) do
          endpoint:close('process endpoint wrap failed')
        end
        for other, value in pairs(parents) do
          if other ~= which and not endpoints[other] then
            opts.close_raw(value)
          end
        end
        if opts.abort then
          opts.abort()
        end
        return nil, IOError.normalise(err, { domain = 'process', action = 'wrap_' .. which })
      end
      restrict(handle, which)
      endpoints[which] = handle
    end
    return endpoints
  end
end
M.io = ProcessIO

return M
