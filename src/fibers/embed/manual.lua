-- Small deterministic host for embedding and tests.
--
-- ManualHost owns only time, readiness and final host-method injection. It does
-- not simulate pipes, sockets, DNS, datagrams, processes or files.

local WaitSet = require('fibers.embed.wait_set')
local Label = require('fibers.internal.label')

local next_manual = 0

local Manual = {}
Manual.__index = Manual

local FINAL_METHODS = {
  'create_pipe',
  'create_listener',
  'start_dial',
  'create_datagram',
  'resolve',
  'start_process',
  'file_provider',
}

local CAPABILITY_BY_METHOD = {
  create_pipe = 'pipe',
  create_listener = 'socket',
  start_dial = 'socket',
  create_datagram = 'datagram',
  resolve = 'resolver',
  start_process = 'process',
  file_provider = 'file',
}

function Manual.is_supported()
  return true
end

function Manual.support_reason()
  return nil
end

function Manual.new(opts)
  opts = opts or {}
  local initial = opts.now
  local now_fn = type(initial) == 'function' and initial or nil
  next_manual = next_manual + 1
  local host = Label.attach(setmetatable({
    _fibers_id = 'manual-host-' .. tostring(next_manual),
    kind = opts.kind or 'manual',
    family = opts.family or opts.kind or 'manual',
    wait_domain = opts.wait_domain or opts.family or opts.kind or 'manual',
    _now = tonumber(initial) or 0,
    _now_fn = now_fn,
    _sleep = opts.sleep,
    auto_advance_time = opts.auto_advance_time ~= false,
    ready = {},
    capabilities = { time = true, readiness = true },
  }, Manual), opts.label)

  host.now = function()
    return host._now_fn and host._now_fn() or host._now
  end

  for i = 1, #FINAL_METHODS do
    local name = FINAL_METHODS[i]
    local method = opts[name]
    if type(method) == 'function' then
      host[name] = method
      host.capabilities[CAPABILITY_BY_METHOD[name]] = true
    end
  end

  for name, value in pairs(opts.capabilities or {}) do
    if value ~= false and value ~= nil then
      host.capabilities[name] = value
    end
  end

  return host
end

function Manual:sleep(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if self._sleep then
    return self._sleep(seconds)
  end
  if not self._now_fn then
    self._now = self._now + seconds
  end
  return true
end

function Manual:set_time(value)
  if self._now_fn then
    error('cannot set time when ManualHost uses opts.now function', 2)
  end
  self._now = tonumber(value) or self._now
  return self._now
end

function Manual:advance(value)
  return self:set_time(self._now + (tonumber(value) or 0))
end

function Manual:set_readiness(key, mode, value)
  mode = WaitSet.normalise_mode(mode)
  local record = self.ready[key] or {}
  self.ready[key] = record
  record[mode] = value == nil and true or value or nil
  return true
end

function Manual:readable(key)
  return self:set_readiness(key, 'read', true)
end

function Manual:writable(key)
  return self:set_readiness(key, 'write', true)
end

function Manual:clear_readiness(key, mode)
  local record = self.ready[key]
  if not record then
    return true
  end
  if mode == nil then
    self.ready[key] = nil
  else
    record[WaitSet.normalise_mode(mode)] = nil
  end
  return true
end

function Manual:is_ready(key, mode)
  local record = self.ready[key]
  return not not (record and record[WaitSet.normalise_mode(mode)])
end

function Manual:block(runtime, waits, _status, opts)
  if self.closed then
    error('fibers.embed.manual: host is closed', 2)
  end
  local set, delivered = WaitSet.build(waits), false
  for i = 1, #set.records do
    local record = set.records[i]
    delivered = WaitSet.deliver(
      runtime,
      record,
      self:is_ready(record.key, 'read'),
      self:is_ready(record.key, 'write')
    ) or delivered
  end
  if delivered then
    return true, 'readiness'
  end
  if set.deadline ~= nil then
    if self.auto_advance_time and (opts or {}).auto_advance_time ~= false then
      if not self._now_fn and self._now < set.deadline then
        self._now = set.deadline
      end
      return true, 'time'
    end
    return nil, 'time-not-ready'
  end
  return nil, #set.records > 0 and 'readiness-not-ready' or 'unsupported-waits'
end

function Manual:close()
  if self.closed then
    return true
  end
  self.closed = true
  return true
end

return Manual
