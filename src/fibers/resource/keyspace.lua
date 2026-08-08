-- Lazy per-key committed locations for trusted resource implementations.

local Facility = require('fibers.resource.authoring')
local Contract = require('fibers.internal.contract')

local Keyspace = {}
Keyspace.__index = Keyspace
Keyspace.ABSENT = Facility.ABSENT

local KEYSPACE_OPTIONS = {
  values = true, algebra = true, domain = true, absent = true,
  clone_initial = true, clone_value = true, put_equal = true, remove_idempotent = true,
}

function Keyspace.new(owner, spec)
  if type(owner) ~= 'table' then error('Keyspace.new owner must be a table', 2) end
  spec = Contract.options(spec, KEYSPACE_OPTIONS, 'Keyspace.new specification', 2)
  if spec.algebra == nil then error('Keyspace.new requires algebra', 2) end
  if spec.values ~= nil and type(spec.values) ~= 'table' then
    error('Keyspace.new values must be a table or nil', 2)
  end
  Contract.optional_function(spec.clone_initial, 'Keyspace.new clone_initial', 2)
  Contract.optional_function(spec.clone_value, 'Keyspace.new clone_value', 2)
  Contract.optional_boolean(spec.put_equal, 'Keyspace.new put_equal', 2)
  Contract.optional_boolean(spec.remove_idempotent, 'Keyspace.new remove_idempotent', 2)
  return setmetatable({
    owner = owner,
    initial = spec.values or {},
    locations = {},
    algebra = spec.algebra,
    domain = spec.domain,
    absent = spec.absent,
    clone_initial = spec.clone_initial,
    clone_value = spec.clone_value,
    put_equal = spec.put_equal,
    remove_idempotent = spec.remove_idempotent,
  }, Keyspace)
end

function Keyspace:location(key)
  local location = self.locations[key]
  if location then return location end

  local initial = self.initial[key]
  self.initial[key] = nil
  if initial == nil and self.absent then initial = self.absent end
  if self.clone_initial then initial = self.clone_initial(initial) end
  location = Facility.location(self.owner, {
    algebra = self.algebra,
    domain = self.domain,
    value = initial,
    key = key,
    clone_value = self.clone_value,
    put_equal = self.put_equal,
    remove_idempotent = self.remove_idempotent,
  })
  self.locations[key] = location
  return location
end


return Keyspace
