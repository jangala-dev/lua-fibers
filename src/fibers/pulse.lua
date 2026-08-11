-- Coalescing broadcast notification from Counter + Cell.

local Counter = require('fibers.resource.counter')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Completion = require('fibers.resource.completion')

local Pulse = {}
Pulse.__index = Pulse

local next_id = 0

local function non_negative_integer(value, label, level)
  if type(value) ~= 'number' or value < 0 or value % 1 ~= 0 then
    error(label .. ' must be a non-negative integer', level or 3)
  end
  return value
end

function Pulse.new(initial)
  initial = non_negative_integer(initial or 0, 'pulse initial version', 2)
  next_id = next_id + 1
  local id = 'pulse-' .. tostring(next_id)
  local pulse = Label.attach(setmetatable({
    _fibers_id = id,
    _version = Counter.new(initial),
    _closed = Completion.new(),
  }, Pulse))
  Label.child(pulse._version, pulse, 'version')
  Label.child(pulse._closed, pulse, 'closed')
  return pulse
end

function Pulse:version_op()
  return self._version:read_op()
end


function Pulse:why_op()
  return self._closed:read_op():map(function(state)
    return state.kind == 'succeeded' and state.values[1] or nil
  end)
end

function Pulse:is_closed_op()
  return self._closed:read_op():map(function(state)
    return state.kind ~= 'pending'
  end)
end

function Pulse:signal_op()
  local signal = Op.each({
    self._closed:pending_op(),
    self._version:bump_op(),
  }):map(function(rows)
    return rows[2][1]
  end)

  return signal:or_else(self._closed:success_op():map(function() return nil end))
end

function Pulse:close_op(reason)
  return self._closed:publish_success_op(reason):map(function() return true end)
end

function Pulse:changed_op(last_seen)
  non_negative_integer(last_seen, 'pulse changed last_seen', 2)

  local changed = self._version:at_least_op(last_seen + 1):map(function(version)
    return version, nil
  end)

  local ended = self._closed:success_op():map(function(reason)
    return nil, reason
  end)

  return changed:or_else(ended)
end

function Pulse:next_op()
  return self._version:read_op():and_then(Op.guard(function(version)
    return self:changed_op(version)
  end))
end





Direct.install(Pulse, { 'version', 'why', 'is_closed', 'signal', 'close', 'changed', 'next' })

return Pulse
