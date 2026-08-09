-- Shared process status, lifecycle and stdio machinery.

local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')
local Op = require('fibers.op')
local HostOffer = require('fibers.io.offer')

local M = {}
local REQUIRED_PROCESS_METHODS = { 'open_exit_op', 'exit_op', 'signal', 'close' }


local function close_returned(value, reason, errors, role)
  if value == nil then return end
  if type(value.close) ~= 'function' then
    errors[#errors + 1] = IOError.protocol('host', 'start_process_cleanup',
      'returned host value has no close method', { value_role = role })
    return
  end
  IOError.capture_cleanup(errors, 'host', 'start_process_cleanup', { value_role = role },
    value.close, value, reason)
end

local function invalid_contract(host, missing, cleanup_errors)
  local fields = {
    host = host and Label.describe(host, host.kind or host.family) or nil,
    missing = missing,
  }
  if cleanup_errors and #cleanup_errors > 0 then fields.cleanup_errors = cleanup_errors end
  return IOError.protocol('host', 'start_process', 'host process provider returned an invalid process handle', fields)
end

local function dispose_invalid_return(process, endpoints, host, missing)
  local errors = {}
  for key, endpoint in pairs(type(endpoints) == 'table' and endpoints or {}) do
    close_returned(endpoint, 'invalid host process contract', errors, 'endpoint:' .. tostring(key))
  end
  close_returned(process, 'invalid host process contract', errors, 'process')
  return invalid_contract(host, missing, errors)
end

-- One host-independent launch boundary. Direct waitpid providers, reaper-process
-- providers, simulated hosts and future platform implementations all return the
-- same process-handle contract beneath the public Process Lifetime.
function M.start(host, spec)
  if not host or type(host.start_process) ~= 'function' then
    return nil, nil, IOError.unsupported('host', 'process', { host = host and Label.describe(host, host.kind or host.family) or nil })
  end
  local process, endpoints, err = host:start_process(spec)
  if not process then
    return nil, nil, err or endpoints
  end
  if endpoints ~= nil and type(endpoints) ~= 'table' then
    return nil, nil, dispose_invalid_return(process, nil, host, 'endpoints')
  end

  for i = 1, #REQUIRED_PROCESS_METHODS do
    local name = REQUIRED_PROCESS_METHODS[i]
    if type(process[name]) ~= 'function' then
      return nil, nil, dispose_invalid_return(process, endpoints, host, name)
    end
  end
  local pid = type(process.pid) == 'function' and process:pid() or process.pid or process._pid
  if pid == nil then
    return nil, nil, dispose_invalid_return(process, endpoints, host, 'pid')
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
    code = Contract.non_negative_integer(code, 'process exit code', 3)
    return { kind = 'exited', code = code, success = code == 0 }
  end

  function M.signalled(signals, number, core_dumped)
    number = Contract.positive_integer(number, 'process signal number', 3)
    Contract.optional_boolean(core_dumped, 'process core_dumped', 3)
    return {
      kind = 'signalled',
      signal = number,
      signal_name = signals.name(number),
      core_dumped = core_dumped == true,
      success = false,
    }
  end

  function M.wait(spec, pid, nonblocking)
    while true do
      local result, errno, message = spec.wait(pid, nonblocking)
      if result or not spec.interrupted(errno) then return result, errno, message end
    end
  end

  function M.provider(spec)
    return {
      is_supported = spec.supported,
      support_reason = function()
        local ok, reason = spec.supported()
        return ok and nil or reason
      end,
    }
  end

  function M.handle(class, pid, spec, fields)
    fields = fields or {}
    fields._fibers_id = 'host-process-' .. tostring(pid)
    fields._pid = pid
    fields.poll_interval = spec.poll_interval or 0.025
    local process = Label.attach(setmetatable(fields, class), spec.label)
    IOAudit.created(process, { kind = 'process_handle' })
    return process
  end

  function M.class(spec)
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
      if not self.exit_source then
        local handle = spec.exit_handle(self)
        self.exit_source = HostOffer.new({
          label = Label.describe(self, self._fibers_id or 'process') .. ':exit',
          domain = 'process', action = 'reap', role = 'process_exit_completion',
          one_shot = true, capacity = 1, handle = handle,
          mode = handle and 'read' or 'poll', poll_interval = self.poll_interval,
          pull = function() return spec.reap(self) end,
        })
      end
      return self.exit_source:open_op(scope)
    end

    function Process:exit_op()
      if self.reaped and self.status then return Op.always(self.status) end
      if not self.exit_source then
        return Op.always(nil, IOError.protocol('process', 'exit',
          'process exit source is not open', { pid = self._pid }))
      end
      return self.exit_source:result_op()
    end

    function Process:signal(value, target)
      if self.reaped then
        return nil, IOError.closed('process', 'signal', { pid = self._pid })
      end
      local number, err = spec.signals.normalise(value)
      if not number then return nil, err end
      local destination = target == 'group' and -math.abs(self.group_id or self._pid) or self._pid
      local ok, errno, message = spec.kill(destination, number)
      if ok then return true end
      return nil, IOError.system('process', 'signal',
        message or spec.message(errno), spec.name_of and spec.name_of(errno), errno,
        { pid = self._pid, signal = number, target = target })
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

  function M.close_all(values, close_raw)
    for _, value in pairs(values or {}) do close_raw(value) end
  end

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
          M.close_all(stdio.all, close_raw)
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

  local WRAP_OPTIONS = {
    host = true, label = Contract.non_empty_string, pid = true, parents = Contract.table,
    wrap = Contract.func, close_raw = Contract.func, nonblocking = Contract.boolean,
    cloexec = Contract.boolean, abort = Contract.func,
  }

  function M.wrap(opts)
    opts = Contract.record(opts, WRAP_OPTIONS, 'process host wrap options', 2)
    if opts.parents == nil or opts.wrap == nil or opts.close_raw == nil then
      error('process host wrap requires parents, wrap and close_raw', 2)
    end
    local endpoints = {}
    local parents = opts.parents
    for which, raw in pairs(parents) do
      local handle, err = opts.wrap(raw, {
        host = opts.host,
        label = (opts.label or ('process-' .. tostring(opts.pid))) .. ':' .. which,
        nonblocking = opts.nonblocking ~= false,
        cloexec = opts.cloexec,
        readable = which ~= 'stdin',
        writable = which == 'stdin',
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
      endpoints[which] = handle
    end
    return endpoints
  end
end
M.io = ProcessIO

return M
