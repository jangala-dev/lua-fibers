-- Independent keyed presence slots.
--
-- Each key is its own transactional location.  Values are non-nil: nil means
-- absence, as it does in ordinary Lua tables.

local Facility = require('fibers.resource.authoring')
local perform = require('fibers.perform')
local Op = require('fibers.op')

local Keyed = {}
Keyed.__index = Keyed

local Kind = Facility.kind('keyed')
local ABSENT = Facility.Keyspace.ABSENT
local FALSE = Op.always(false)

local function yes()
  return true
end

local function require_key(key, operation)
  if key == nil then
    error('keyed ' .. operation .. ' requires a key', 3)
  end
end

local function require_value(value)
  if value == nil then
    error('keyed values cannot be nil', 3)
  end
end

local function create(entries, name)
  if type(entries) ~= 'table' then
    error('keyed entries must be a table', 3)
  end

  local values = {}
  for key, value in pairs(entries) do
    require_value(value)
    values[key] = value
  end

  local keyed = Facility.identity(setmetatable({}, Keyed), Kind, name)
  keyed._space = Facility.Keyspace.new(keyed, {
    values = values,
    algebra = 'presence',
    domain = 'presence',
    absent = ABSENT,
  })
  return keyed
end

function Keyed.new(name)
  return create({}, name)
end

function Keyed.from(entries, name)
  return create(entries, name)
end

local function operations(self, key)
  local location = self._space:location(key)
  local cached = location._keyed_operations
  if cached then
    return cached
  end

  cached = {
    get = Facility.op(
      self,
      Kind,
      Facility.claim({
        location = location,
        demand = 'up',
        query = { kind = 'predicate', predicate = 'present' },
        result = Facility.result.value,
      })
    ),
    take = Facility.op(
      self,
      Kind,
      Facility.claim({
        location = location,
        demand = 'up',
        query = { kind = 'predicate', predicate = 'present' },
        change = Facility.change.take(),
        result = Facility.result.value,
      })
    ),
    put = Facility.descriptor(self, Kind, 'patch', {
      location = location,
      bind = 'presence_put',
      result = Facility.result.boolean,
    }),
  }

  location._keyed_operations = cached
  return cached
end

function Keyed:get_op(key)
  require_key(key, 'get')
  return operations(self, key).get
end

function Keyed:get(key)
  return perform(self:get_op(key))
end

function Keyed:take_op(key)
  require_key(key, 'take')
  return operations(self, key).take
end

function Keyed:take(key)
  return perform(self:take_op(key))
end

function Keyed:put_op(key, value)
  require_key(key, 'put')
  require_value(value)
  return Facility.occurrence(operations(self, key).put, value)
end

function Keyed:put(key, value)
  return perform(self:put_op(key, value))
end

function Keyed:insert_op(key, value)
  require_key(key, 'insert')
  require_value(value)

  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self._space:location(key),
      demand = 'down',
      query = { kind = 'predicate', predicate = 'absent' },
      change = Facility.change.put(value),
      result = Facility.result.boolean,
    })
  )
end

function Keyed:insert(key, value)
  return perform(self:insert_op(key, value))
end

function Keyed:contains_op(key)
  return self:get_op(key):map(yes):or_else(FALSE)
end

function Keyed:contains(key)
  return perform(self:contains_op(key))
end

function Keyed:remove_op(key)
  return self:take_op(key):map(yes):or_else(FALSE)
end

function Keyed:remove(key)
  return perform(self:remove_op(key))
end

Keyed.Kind = Kind

return Keyed
