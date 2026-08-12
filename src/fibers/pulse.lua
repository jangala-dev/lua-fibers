-- Coalescing broadcast notification from Counter + Cell.

local Counter = require('fibers.resource.counter')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Completion = require('fibers.resource.completion')
local Contract = require('fibers.internal.contract')

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new(initial)
  initial = initial or 0
  local pulse = Label.attach(Label.identity(setmetatable({
    _version = Counter.new(initial),
    _closed = Completion.new(),
  }, Pulse), 'pulse'))
  Label.child(pulse._version, pulse, 'version')
  Label.child(pulse._closed, pulse, 'closed')
  return pulse
end

function Pulse:version_op()
  return self._version:read_op()
end


function Pulse:why_op() return self._closed:value_op() end
function Pulse:is_closed_op() return self._closed:is_terminal_op() end

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
  Contract.non_negative_integer(last_seen, 'pulse changed last_seen', 2)

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
