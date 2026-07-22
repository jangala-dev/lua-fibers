-- Shared lazy per-key location storage for trusted facilities.
-- Mutable public tables, where retained for compatibility, are confined here.

local Ledger = require('fibers.internal.kernel.ledger')
local Algebra = require('fibers.internal.kernel.algebra')

local Keyspace = {}
Keyspace.__index = Keyspace

function Keyspace.new(owner, spec)
  spec = spec or {}
  return setmetatable({
    owner = owner,
    values = spec.values or {},
    versions = spec.versions or {},
    locations = {},
    version = 0,
    algebra = assert(spec.algebra, 'keyspace algebra required'),
    domain = spec.domain,
    absent = spec.absent,
    clone_initial = spec.clone_initial,
    clone_value = spec.clone_value,
    put_equal = spec.put_equal,
    remove_idempotent = spec.remove_idempotent,
    refresh = spec.refresh,
  }, Keyspace)
end

function Keyspace:location(key)
  local location = self.locations[key]
  if location then
    if self.refresh then
      self.refresh(self, key, location)
    end
    return location
  end
  local initial = self.values[key]
  if initial == nil and self.absent then
    initial = self.absent
  end
  if self.clone_initial then
    initial = self.clone_initial(initial)
  end
  location = Ledger.new_location({
    name = self.owner.name .. ':' .. tostring(key),
    algebra = self.algebra,
    domain = self.domain,
    value = initial,
    owner = self.owner,
    key = key,
    clone_value = self.clone_value,
    put_equal = self.put_equal,
    remove_idempotent = self.remove_idempotent,
    apply = function(value, applied)
      if value == self.absent then
        self.values[key] = nil
      else
        self.values[key] = value
      end
      self.versions[key] = applied.version
      self.version = self.version + 1
    end,
  })
  self.locations[key] = location
  return location
end

function Keyspace:keys()
  local keys = {}
  for key in pairs(self.values) do
    keys[key] = true
  end
  for key in pairs(self.locations) do
    keys[key] = true
  end
  return keys
end

function Keyspace:observation(spec)
  spec = spec or {}
  local field = spec.field or 'entries'
  local decode = spec.decode or function(value)
    return value
  end
  local include = spec.include or function()
    return true
  end
  local space = self
  return {
    collect = function(_, read)
      local values = {}
      for key in pairs(space:keys()) do
        local value = read(space:location(key))
        if include(value, key) then
          values[key] = decode(value, key)
        end
      end
      return { [field] = values, version = space.version }
    end,
  }
end

Keyspace.ABSENT = Algebra.ABSENT
return Keyspace
