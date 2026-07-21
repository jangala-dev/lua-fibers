local Facility = require('fibers.internal.facility')
local Keyspace = require('fibers.internal.facility_keyspace')

local Keyed = {}
Keyed.__index = function(self, key)
  if key == 'version' then
    return self._space.version
  end
  return Keyed[key]
end
local Kind = Facility.kind('keyed')
local ABSENT = Keyspace.ABSENT
local NIL = {}
local function enc(value)
  return value == nil and NIL or value
end

function Keyed.new(entries, name)
  local map = Facility.identity(setmetatable({ _nil_sentinel = NIL }, Keyed), Kind, name)
  local values, versions = {}, {}
  for key, value in pairs(entries or {}) do
    values[key], versions[key] = enc(value), 0
  end
  map._space = Keyspace.new(map, {
    values = values,
    versions = versions,
    algebra = 'presence',
    domain = 'presence',
    absent = ABSENT,
  })
  map.entries, map.versions, map._locations = values, versions, map._space.locations
  return map
end
function Keyed:_location(key)
  return self._space:location(key)
end

local function required(key, operation)
  if key == nil then
    error('keyed ' .. operation .. ' requires key', 3)
  end
end
function Keyed:get_op(key)
  required(key, 'get')
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self:_location(key),
      demand = 'up',
      query = { kind = 'predicate', predicate = 'present' },
      result = Facility.result.presence(NIL),
    })
  )
end
function Keyed:peek_op(key)
  required(key, 'peek')
  return Facility.op(self, Kind, Facility.read(self:_location(key), Facility.result.presence(NIL)))
end
function Keyed:contains_op(key)
  required(key, 'contains')
  return Facility.op(self, Kind, Facility.read(self:_location(key), Facility.result.present))
end
function Keyed:put_op(key, value)
  required(key, 'put')
  return Facility.op(self, Kind, Facility.write(self:_location(key), Facility.change.put(enc(value))))
end
function Keyed:put_absent_op(key, value)
  required(key, 'put_absent')
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self:_location(key),
      demand = 'down',
      query = { kind = 'predicate', predicate = 'absent' },
      change = Facility.change.put(enc(value)),
      result = Facility.result.boolean,
    })
  )
end
function Keyed:remove_op(key)
  required(key, 'remove')
  return Facility.op(
    self,
    Kind,
    Facility.conditional({
      location = self:_location(key),
      demand = 'up',
      predicate = 'present',
      immediate = Facility.change.remove(),
      change = Facility.change.take(),
      result = Facility.result.boolean,
    })
  )
end
function Keyed:remove_present_op(key)
  required(key, 'remove_present')
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self:_location(key),
      demand = 'up',
      query = { kind = 'predicate', predicate = 'present' },
      change = Facility.change.take(),
      result = Facility.result.presence(NIL),
    })
  )
end
function Keyed:snapshot_op()
  return Facility.op(self, Kind, Facility.snapshot(self, 'keyed'))
end

Keyed.Kind, Keyed.ABSENT = Kind, ABSENT
return Keyed
