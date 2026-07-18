-- Immediate coverage for newly acquired external resources.
--
-- A Slot is admitted before a committed callback invokes a host acquisition.
-- The callback adopts the returned value synchronously, before it can yield.
-- Once permanent ownership has been established elsewhere, release() removes
-- the Slot's close responsibility. Bundles accept explicitly ordered entry
-- arrays so multi-handle acquisition and rollback never depend on table order.

local HostError = require('fibers.host.error')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')

local Adoption = {}
local Slot = {}
Slot.__index = Slot
local Bundle = {}
Bundle.__index = Bundle
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

function Adoption.bundle(name)
  next_id = next_id + 1
  local id = 'adoption-bundle-' .. tostring(next_id)
  local bundle = Ownership.handle(name or id, {
    kind = 'adoption_bundle',
    values = {},
    order = {},
    released = {},
    closed = false,
  })
  bundle._fibers_settle = Settlement.protocol({
    name = 'adoption_bundle',
    discharge_op = function()
      local Op = require('fibers.op')
      local ok, err = bundle:close('scope settlement')
      return Op.always(ok, err)
    end,
  })
  bundle._fibers_settle_name = 'adoption_bundle'
  return setmetatable(bundle, Bundle)
end

function Bundle:owned(opts)
  opts = opts or {}
  return Owned.item(self, self._fibers_settle, {
    role = opts.role or 'adoption_bundle',
    settle_name = 'adoption_bundle',
  })
end

function Bundle:is_empty()
  return next(self.values) == nil
end

function Bundle:adopt(name, value, close)
  if type(name) ~= 'string' or name == '' then
    close_value(value, close, 'adoption refused')
    return nil, HostError.protocol('adoption', 'adopt_bundle', 'bundle entry name must be non-empty')
  end
  if value == nil then
    return nil, HostError.protocol('adoption', 'adopt_bundle', 'cannot adopt nil')
  end
  if self.closed or self.values[name] ~= nil or self.released[name] then
    close_value(value, close, 'adoption refused')
    return nil,
      HostError.protocol('adoption', 'adopt_bundle', 'bundle entry is unavailable', { entry = name })
  end
  self.values[name] = { value = value, close = close }
  self.order[#self.order + 1] = name
  return value
end

function Bundle:adopt_many(entries)
  if type(entries) ~= 'table' then
    return nil, HostError.protocol('adoption', 'adopt_many', 'entries must be an ordered array')
  end

  local adopted = {}
  for index = 1, #entries do
    local entry = entries[index]
    if type(entry) ~= 'table' then
      return nil,
        HostError.protocol('adoption', 'adopt_many', 'entry must be a table', {
          index = index,
        })
    end

    local name = entry.name or entry[1]
    local value = entry.value
    if value == nil then
      value = entry[2]
    end
    local close = entry.close or entry[3]
    local got, err = self:adopt(name, value, close)
    if not got then
      for i = #adopted, 1, -1 do
        local adopted_name = adopted[i]
        local rec = self.values[adopted_name]
        self.values[adopted_name] = nil
        if rec then
          close_value(rec.value, rec.close, 'bundle adoption rolled back')
        end
      end
      return nil, err
    end
    adopted[#adopted + 1] = name
  end
  return true
end

function Bundle:release(name, expected)
  local rec = self.values[name]
  if not rec then
    return nil, HostError.protocol('adoption', 'release_bundle', 'bundle entry is empty', { entry = name })
  end
  if expected ~= nil and rec.value ~= expected then
    return nil,
      HostError.protocol('adoption', 'release_bundle', 'bundle entry value mismatch', { entry = name })
  end
  self.values[name] = nil
  self.released[name] = true
  return rec.value
end

function Bundle:release_all()
  local out = {}
  for i = 1, #self.order do
    local name = self.order[i]
    local rec = self.values[name]
    if rec then
      out[name] = rec.value
      self.values[name] = nil
      self.released[name] = true
    end
  end
  return out
end

function Bundle:close(reason)
  if self.closed then
    return true
  end
  self.closed = true
  local errors = {}
  for i = #self.order, 1, -1 do
    local name = self.order[i]
    local rec = self.values[name]
    self.values[name] = nil
    if rec then
      local ok, err = close_value(rec.value, rec.close, reason)
      if not ok then
        errors[#errors + 1] = { entry = name, error = err }
      end
    end
  end
  if #errors > 0 then
    return nil,
      HostError.protocol('adoption', 'close_bundle', 'one or more adopted values failed to close', {
        errors = errors,
      })
  end
  return true
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
Adoption.Bundle = Bundle
return Adoption
