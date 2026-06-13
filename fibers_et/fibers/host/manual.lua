-- Deterministic host adapter for tests, examples and embedding sketches.
--
-- ManualHost implements the public host readiness contract without depending on
-- OS polling.  It owns a small readiness table keyed by host handle and mode;
-- block() delivers matching runtime readiness arrivals.  It is deliberately
-- level-like: readiness remains set until clear_readiness is called.

local Host = require('fibers.host')

local Manual = {}
Manual.__index = Manual

local function normalise_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 3) end
  return mode
end

function Manual.new(opts)
  opts = opts or {}
  local self = setmetatable({
    kind = 'manual',
    ready = {},
    auto_advance_time = opts.auto_advance_time ~= false,
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
    _now = opts.now or 0,
  }, Manual)

  self.now = function(_rt) return self._now end
  return self
end

function Manual:set_time(t)
  self._now = tonumber(t) or self._now
  return self._now
end

function Manual:advance(dt)
  self._now = self._now + (tonumber(dt) or 0)
  return self._now
end

function Manual:set_readiness(key, mode, value)
  mode = normalise_mode(mode)
  local k = tostring(key)
  self.ready[k] = self.ready[k] or {}
  if value == false or value == nil then self.ready[k][mode] = nil else self.ready[k][mode] = true end
  return true
end

function Manual:ready(key, mode)
  return self:set_readiness(key, mode or 'read', true)
end

function Manual:readable(key)
  return self:set_readiness(key, 'read', true)
end

function Manual:writable(key)
  return self:set_readiness(key, 'write', true)
end

function Manual:clear_readiness(key, mode)
  local k = tostring(key)
  if not self.ready[k] then return true end
  if mode == nil then
    self.ready[k] = nil
  else
    self.ready[k][normalise_mode(mode)] = nil
  end
  return true
end

function Manual:is_ready(key, mode)
  local rec = self.ready[tostring(key)]
  return not not (rec and rec[normalise_mode(mode)])
end

function Manual:block(rt, waits, status, opts)
  opts = opts or {}
  waits = waits or {}

  local delivered = Host.deliver_ready(rt, waits, function(key, mode)
    return self:is_ready(key, mode)
  end)
  if delivered and delivered > 0 then
    if self.on_wake then self.on_wake('readiness', waits, status) end
    return true, 'readiness'
  end

  local deadline = Host.earliest_deadline(waits)
  if deadline ~= nil then
    if self.auto_advance_time and opts.auto_advance_time ~= false then
      if self._now < deadline then
        if self.on_wait then self.on_wait(deadline, deadline - self._now, waits, status) end
        self._now = deadline
      end
      if self.on_wake then self.on_wake('time', waits, status) end
      return true, 'time'
    end
    return nil, 'time-not-ready'
  end

  if self.on_unsupported then self.on_unsupported(waits, status) end
  if Host.has_readiness_waits(waits) then return nil, 'readiness-not-ready' end
  return nil, 'unsupported-waits'
end

return Manual
