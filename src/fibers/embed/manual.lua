-- Small deterministic host for embedding and tests.
--
-- ManualHost owns only time, readiness and final host-method injection. It does
-- not simulate pipes, sockets, DNS, datagrams, processes or files.

local WaitSet = require('fibers.embed.wait_set')
local Base = require('fibers.internal.host.base')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local next_manual = 0

local Manual = {}
Manual.__index = Manual
setmetatable(Manual, { __index = Base })

local FINAL_METHODS = {
  'create_pipe',
  'create_listener',
  'start_dial',
  'create_datagram',
  'resolve',
  'start_process',
  'file_provider',
}

local function now_option(value, label, level)
  if type(value) == 'function' then return value end
  return Contract.finite_number(value, label, level)
end

local MANUAL_OPTIONS = {
  now = now_option, kind = true, family = true, wait_domain = true,
  sleep = Contract.func, auto_advance_time = Contract.boolean,
  features = Contract.table, label = true,
}
for i = 1, #FINAL_METHODS do MANUAL_OPTIONS[FINAL_METHODS[i]] = Contract.func end

local CAPABILITY_METHODS = {
  pipe = { 'create_pipe' }, socket = { 'create_listener', 'start_dial' },
  datagram = { 'create_datagram' }, resolver = { 'resolve' },
  process = { 'start_process' }, file = { 'file_provider' },
}


function Manual.is_supported()
  return true
end

function Manual.support_reason()
  return nil
end

function Manual.new(opts)
  opts = Contract.options(opts, MANUAL_OPTIONS, 'ManualHost options', 2)
  local initial = opts.now
  local now_fn = type(initial) == 'function' and initial or nil
  next_manual = next_manual + 1
  local host = Label.attach(setmetatable({
    _fibers_id = 'manual-host-' .. tostring(next_manual),
    kind = opts.kind or 'manual',
    family = opts.family or opts.kind or 'manual',
    _wait_domain = opts.wait_domain or opts.family or opts.kind or 'manual',
    _now = now_fn and 0 or (initial == nil and 0 or Contract.finite_number(initial, 'ManualHost opts.now', 2)),
    _now_fn = now_fn,
    _sleep = opts.sleep,
    _auto_advance_time = opts.auto_advance_time ~= false,
    _ready = {},
  }, Manual), opts.label)

  local features = { time = true, readiness = true }
  Base.init(host, features)
  host.now = function() return host._now_fn and host._now_fn() or host._now end

  for i = 1, #FINAL_METHODS do
    local name = FINAL_METHODS[i]
    if opts[name] then host[name] = opts[name] end
  end

  for name, value in pairs(opts.features or {}) do
    if CAPABILITY_METHODS[name] then
      error('ManualHost features.' .. name .. ' is derived from its method contract', 2)
    end
    if value ~= false and value ~= nil then features[name] = value end
  end
  for capability, methods in pairs(CAPABILITY_METHODS) do
    local present = true
    for i = 1, #methods do present = present and type(host[methods[i]]) == 'function' end
    if present then features[capability] = true end
  end

  return host
end

function Manual:sleep(seconds)
  seconds = Contract.non_negative_number(seconds, 'ManualHost sleep seconds', 2)
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
  self._now = Contract.finite_number(value, 'ManualHost time', 2)
  return self._now
end

function Manual:advance(value)
  value = Contract.non_negative_number(value, 'ManualHost advance seconds', 2)
  return self:set_time(self._now + value)
end

function Manual:set_readiness(key, mode, value)
  mode = WaitSet.normalise_mode(mode)
  local record = self._ready[key] or {}
  self._ready[key] = record
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
  local record = self._ready[key]
  if not record then
    return true
  end
  if mode == nil then
    self._ready[key] = nil
  else
    record[WaitSet.normalise_mode(mode)] = nil
  end
  return true
end

function Manual:_is_ready(key, mode)
  local record = self._ready[key]
  return not not (record and record[WaitSet.normalise_mode(mode)])
end

function Manual:block(runtime, waits, _status, opts)
  if self._closed then error('fibers.embed.manual: host is closed', 2) end
  local set, delivered = WaitSet.build(waits), false
  for i = 1, #set.records do
    local record = set.records[i]
    delivered = WaitSet.deliver(
      runtime,
      record,
      self:_is_ready(record.key, 'read'),
      self:_is_ready(record.key, 'write')
    ) or delivered
  end
  if delivered then
    return true, 'readiness'
  end
  if set.deadline ~= nil then
    if self._auto_advance_time and (opts or {}).auto_advance_time ~= false then
      if not self._now_fn and self._now < set.deadline then
        self._now = set.deadline
      end
      return true, 'time'
    end
    return nil, 'time-not-ready'
  end
  return nil, #set.records > 0 and 'readiness-not-ready' or 'unsupported-waits'
end

return Manual
