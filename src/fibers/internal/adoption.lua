-- Immediate coverage for newly acquired external resources.
--
-- A Slot is admitted before a committed callback invokes a host acquisition.
-- The callback adopts the returned value synchronously, before it can yield.
-- Once permanent ownership has been established elsewhere, release() removes
-- the Slot's close responsibility.

local HostError = require('fibers.host.error')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')

local Adoption = {}
local Slot = {}
Slot.__index = Slot
local next_id = 0

local function close_value(value, close, reason)
  if value == nil then
    return true
  end
  if type(close) == 'function' then
    return close(value, reason)
  end
  if type(value) == 'table' and type(value.close) == 'function' then
    return value:close(reason)
  end
  return nil, HostError.unsupported('adoption', 'close')
end

function Adoption.slot(name)
  next_id = next_id + 1
  local id = 'adoption-' .. tostring(next_id)
  local slot = Ownership.handle(name or id, {
    kind = 'adoption_slot',
    value = nil,
    close_value = nil,
    released = false,
    closed = false,
  })
  slot._fibers_settle = Settlement.protocol({
    name = 'adoption_slot',
    discharge_op = function()
      local Op = require('fibers.op')
      local ok, err = slot:close('scope settlement')
      return Op.always(ok, err)
    end,
  })
  slot._fibers_settle_name = 'adoption_slot'
  return setmetatable(slot, Slot)
end

function Slot:owned(opts)
  opts = opts or {}
  return Owned.item(self, self._fibers_settle, {
    role = opts.role or 'adoption_slot',
    settle_name = 'adoption_slot',
  })
end

function Slot:is_empty()
  return self.value == nil
end

function Slot:adopt(value, close)
  if value == nil then
    return nil, HostError.protocol('adoption', 'adopt', 'cannot adopt nil')
  end
  if self.closed or self.released or self.value ~= nil then
    close_value(value, close, 'adoption refused')
    return nil, HostError.protocol('adoption', 'adopt', 'adoption slot is not empty')
  end
  self.value = value
  self.close_value = close
  return value
end

function Slot:release(expected)
  if self.value == nil then
    return nil, HostError.protocol('adoption', 'release', 'adoption slot is empty')
  end
  if expected ~= nil and expected ~= self.value then
    return nil, HostError.protocol('adoption', 'release', 'adoption slot value mismatch')
  end
  local value = self.value
  self.value = nil
  self.close_value = nil
  self.released = true
  return value
end

function Slot:close(reason)
  if self.closed then
    return true
  end
  self.closed = true
  local value, close = self.value, self.close_value
  self.value, self.close_value = nil, nil
  if value == nil then
    return true
  end
  return close_value(value, close, reason)
end

function Adoption.adopt_pair(read_slot, write_slot, read_value, write_value, close)
  local r, err = read_slot:adopt(read_value, close)
  if not r then
    close_value(write_value, close, 'paired adoption failed')
    return nil, err
  end
  local w, werr = write_slot:adopt(write_value, close)
  if not w then
    read_slot:close('paired adoption failed')
    return nil, werr
  end
  return r, w
end

Adoption.Slot = Slot
return Adoption
