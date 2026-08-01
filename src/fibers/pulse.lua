-- Coalescing broadcast notification from Counter + Cell.

local Counter = require('fibers.resource.counter')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Pulse = {}
Pulse.__index = Pulse

local OPEN = {}

local function child_name(name, suffix)
  return name and name .. ':' .. suffix or nil
end

local function closed(status)
  return status ~= OPEN
end

local function non_negative_integer(value, label, level)
  if type(value) ~= 'number' or value < 0 or value % 1 ~= 0 then
    error(label .. ' must be a non-negative integer', level or 3)
  end
  return value
end

function Pulse.new(initial, name)
  initial = non_negative_integer(initial or 0, 'pulse initial version', 2)
  return setmetatable({
    _version = Counter.new(initial, child_name(name, 'version')),
    _status = Cell.new(OPEN, child_name(name, 'status')),
  }, Pulse)
end

function Pulse:version_op()
  return self._version:read_op()
end


function Pulse:why_op()
  return self._status:read_op():map(function(status)
    return closed(status) and status.reason or nil
  end)
end


function Pulse:is_closed_op()
  return self._status:read_op():map(closed)
end


function Pulse:signal_op()
  local signal = Op.each({
    self._status:expect_op(OPEN),
    self._version:bump_op(),
  }):map(function(rows)
    return rows[2][1]
  end)

  return signal:or_else(self._status:wait_until_op(closed):map(function()
    return nil
  end))
end

function Pulse:close_op(reason)
  local close = self._status:expect_op(OPEN):and_then(self._status:write_op({ reason = reason }):map(function()
      return true
    end))

  return close:or_else(self._status:wait_until_op(closed):map(function()
    return true
  end))
end

function Pulse:changed_op(last_seen)
  non_negative_integer(last_seen, 'pulse changed last_seen', 2)

  local changed = self._version:at_least_op(last_seen + 1):map(function(version)
    return version, nil
  end)

  local ended = self._status:wait_until_op(closed):map(function(status)
    return nil, status.reason
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
