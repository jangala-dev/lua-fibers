-- Lazy per-key committed locations for trusted resource implementations.

local Facility = require('fibers.resource.authoring')

local Keyspace = {}
Keyspace.__index = Keyspace
Keyspace.ABSENT = Facility.ABSENT

function Keyspace.new(owner, spec)
  spec = spec or {}
  return setmetatable({
    owner = owner,
    initial = spec.values or {},
    locations = {},
    algebra = assert(spec.algebra, 'keyspace algebra required'),
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

function Keyspace:keys()
  local keys = {}
  for key in pairs(self.initial) do keys[key] = true end
  for key in pairs(self.locations) do keys[key] = true end
  return keys
end

function Keyspace:version()
  local version = 0
  for _, location in pairs(self.locations) do
    version = version + (location.version or 0)
  end
  return version
end

function Keyspace:snapshot(decode, include)
  decode = decode or function(value) return value end
  include = include or function(value) return value ~= self.absent end
  local values = {}
  for key in pairs(self:keys()) do
    local value = self:location(key).value
    if include(value, key) then values[key] = decode(value, key) end
  end
  return values
end

function Keyspace:versions_snapshot()
  local versions = {}
  for key in pairs(self:keys()) do
    versions[key] = self:location(key).version or 0
  end
  return versions
end

function Keyspace:observation(spec)
  spec = spec or {}
  local field = spec.field or 'entries'
  local decode = spec.decode or function(value) return value end
  local include = spec.include or function() return true end
  local space = self
  return {
    collect = function(_, read)
      local values, version = {}, 0
      for key in pairs(space:keys()) do
        local location = space:location(key)
        local value = read(location)
        version = version + (location.version or 0)
        if include(value, key) then values[key] = decode(value, key) end
      end
      return { [field] = values, version = version }
    end,
  }
end

return Keyspace
