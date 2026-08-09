-- Independent keyed presence slots.
--
-- Each key is its own transactional location. Values are non-nil: nil means
-- absence, as it does in ordinary Lua tables.
local Facility = require('fibers.resource.authoring')
local Keyspace = require('fibers.resource.keyspace')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Keyed = {}
Keyed.__index = Keyed

local Kind = Facility.kind('keyed')
local ABSENT = Keyspace.ABSENT
local FALSE = Op.always(false)
local function yes() return true end

local function require_key(key, operation)
  if key == nil then error('keyed ' .. operation .. ' requires a key', 3) end
end

local function require_value(value)
  if value == nil then error('keyed values cannot be nil', 3) end
end

local function get(value)
  if value == ABSENT then return nil end
  return Facility.outcome(nil, value)
end

local function take(value)
  if value == ABSENT then return nil end
  return Facility.outcome(Facility.patch.take(), value)
end

local function insert(current, value)
  if current ~= ABSENT then return nil end
  return Facility.outcome(Facility.patch.put(value), true)
end

local function create(entries)
  if type(entries) ~= 'table' then error('keyed entries must be a table', 3) end
  local values = {}
  for key, value in pairs(entries) do
    require_value(value)
    values[key] = value
  end
  local keyed = Facility.identity(setmetatable({}, Keyed), Kind)
  keyed._space = Keyspace.new(keyed, {
    values = values, algebra = 'presence', domain = 'presence', absent = ABSENT,
  })
  return keyed
end

function Keyed.new() return create({}) end
function Keyed.from(entries) return create(entries) end

local function operations(self, key)
  local location = self._space:location(key)
  local cached = location._keyed_operations
  if cached then return cached end
  cached = {
    get = Facility.op(Facility.rule.inspect({
      location = location, resource = self, demand = 'up',
      visibility = 'together', step = get,
    })),
    take = Facility.op(Facility.rule.change({
      location = location, resource = self, demand = 'up',
      visibility = 'together', supply = 'down', step = take,
    })),
    put = Facility.presence_put(location, Facility.result.boolean, self),
    insert = Facility.rule.change({
      location = location, resource = self, demand = 'down',
      visibility = 'together', supply = 'up', step = insert,
    }),
  }
  location._keyed_operations = cached
  return cached
end

function Keyed:get_op(key)
  require_key(key, 'get')
  return operations(self, key).get
end

function Keyed:take_op(key)
  require_key(key, 'take')
  return operations(self, key).take
end

function Keyed:put_op(key, value)
  require_key(key, 'put')
  require_value(value)
  return Facility.bind(operations(self, key).put, value)
end

function Keyed:insert_op(key, value)
  require_key(key, 'insert')
  require_value(value)
  return Facility.bind(operations(self, key).insert, value)
end

function Keyed:contains_op(key) return self:get_op(key):map(yes):or_else(FALSE) end
function Keyed:remove_op(key) return self:take_op(key):map(yes):or_else(FALSE) end

Keyed.Kind = Kind
Direct.install(Keyed, { 'get', 'take', 'put', 'insert', 'contains', 'remove' })

return Keyed
