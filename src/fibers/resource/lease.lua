local Facility = require('fibers.resource.authoring')
local Keyspace = Facility.Keyspace

local Lease = {}
Lease.__index = function(self, key)
  if key == 'version' then
    return self._space.version
  end
  return Lease[key]
end
local Kind = Facility.kind('lease')

local function copy_map(values)
  local out = {}
  for key, value in pairs(values or {}) do
    out[key] = value
  end
  return out
end

function Lease.new(compat, name)
  local lease = Facility.identity(setmetatable({ compat = compat or { lease = {} } }, Lease), Kind, name)
  local holders, versions = {}, {}
  lease._space = Keyspace.new(lease, {
    values = holders,
    versions = versions,
    algebra = 'finite_map',
    domain = 'finite_map',
    clone_initial = copy_map,
    put_equal = true,
    remove_idempotent = true,
    refresh = function(space, subject, location)
      if space.values[subject] ~= location.value then
        location.value = copy_map(space.values[subject])
        location.version = (location.version or 0) + 1
        space.versions[subject] = location.version
      end
    end,
  })
  lease.holders, lease.versions, lease._locations = holders, versions, lease._space.locations
  lease._snapshot_op = Facility.op(
    lease,
    Kind,
    Facility.snapshot(
      lease,
      lease._space:observation({
        field = 'holders',
        decode = copy_map,
      })
    )
  )
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
  return Facility.op(
    self,
    Kind,
    Facility.admit({
      location = location,
      demand = 'down',
      key = holder,
      value = mode,
      compatibility = self.compat,
      result = Facility.result.boolean,
    })
  )
end
function Lease:release_op(subject, holder)
  if subject == nil then
    error('lease release requires subject', 2)
  end
  if holder == nil then
    error('lease release requires holder', 2)
  end
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self:_location(subject),
      demand = 'up',
      query = { kind = 'predicate', predicate = 'map_present', key = holder },
      change = Facility.change.map_remove(holder),
      result = Facility.result.boolean,
    })
  )
end
function Lease:snapshot_op()
  return self._snapshot_op
end

Lease.Kind = Kind
return Lease
