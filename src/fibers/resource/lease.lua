local Facility = require('fibers.resource.authoring')
local Keyspace = require('fibers.resource.keyspace')
local Direct = require('fibers.internal.direct')

local Lease = {}
local Kind = Facility.kind('lease')

local function copy_map(values)
  local out = {}
  for key, value in pairs(values or {}) do
    out[key] = value
  end
  return out
end

Lease.__index = function(self, key)
  if key == 'version' then
    return self._space:version()
  end
  if key == 'holders' then
    return self._space:snapshot(copy_map, function(value)
      return type(value) == 'table' and next(value) ~= nil
    end)
  end
  if key == 'versions' then
    return self._space:versions_snapshot()
  end
  return Lease[key]
end

function Lease.new(compat, name)
  local lease = Facility.identity(setmetatable({ compat = compat or { lease = {} } }, Lease), Kind, name)
  lease._space = Keyspace.new(lease, {
    algebra = 'finite_map',
    domain = 'finite_map',
    clone_initial = copy_map,
    put_equal = true,
    remove_idempotent = true,
  })
  return lease
end
function Lease:_location(subject)
  return self._space:location(subject)
end

function Lease:acquire_op(subject, mode, holder)
  if subject == nil then
    error('lease acquire requires subject', 2)
  end
  if mode == nil then
    error('lease acquire requires mode', 2)
  end
  if holder == nil then
    error('lease acquire requires holder', 2)
  end
  local location = self:_location(subject)
  return Facility.op(Facility.transition({
    location = location,
    resource = self,
    demand = 'down',
    accepts_supply = true,
    supplies = 'up',
    writes = true,
    step = function(holders)
      for other, held_mode in pairs(holders or {}) do
        if other ~= holder then
          local forward = self.compat[mode] and self.compat[mode][held_mode] == true
          local reverse = self.compat[held_mode] and self.compat[held_mode][mode] == true
          if not (mode == held_mode or forward and reverse) then
            return nil
          end
        end
      end
      return Facility.outcome(Facility.change.map_put(holder, mode, 'overwrite'), true)
    end,
  }))
end

function Lease:release_op(subject, holder)
  if subject == nil then
    error('lease release requires subject', 2)
  end
  if holder == nil then
    error('lease release requires holder', 2)
  end
  return Facility.op(Facility.transition({
    location = self:_location(subject),
    resource = self,
    demand = 'up',
    accepts_supply = true,
    supplies = 'down',
    writes = true,
    step = function(holders)
      if holders[holder] == nil then
        return nil
      end
      return Facility.outcome(Facility.change.map_remove(holder), true)
    end,
  }))
end

Lease.Kind = Kind
Direct.install(Lease, { 'acquire', 'release' })

return Lease
