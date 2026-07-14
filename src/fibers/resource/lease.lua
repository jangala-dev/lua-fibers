local Op = require('fibers.op')
local Substrate = require('fibers.internal.kernel.store')
local Program = require('fibers.internal.kernel.ir')

local Lease = {}
Lease.__index = Lease
local Kind = { name = 'lease' }
local next_id = 0

function Lease.new(compat, name)
  next_id = next_id + 1
  return setmetatable({
    name = name or ('lease-' .. tostring(next_id)),
    _fibers_id = 'lease-' .. tostring(next_id),
    _fibers_kind = Kind,
    holders = {},
    versions = {},
    version = 0,
    compat = compat or { lease = {} },
    _locations = {},
  }, Lease)
end

function Lease:_location(subject)
  local loc = self._locations[subject]
  if loc then
    -- Preserve the public mutable-table behaviour. A systems implementation
    -- should keep committed holder state opaque.
    if self.holders[subject] ~= loc.value then
      local fresh = {}
      for owner, mode in pairs(self.holders[subject] or {}) do
        fresh[owner] = mode
      end
      loc.value = fresh
      loc.version = (loc.version or 0) + 1
      self.versions[subject] = loc.version
    end
    return loc
  end
  local initial = {}
  for owner, mode in pairs(self.holders[subject] or {}) do
    initial[owner] = mode
  end
  loc = Substrate.new_location({
    name = self.name .. ':' .. tostring(subject),
    merge = 'finite_map',
    domain = 'finite_map',
    value = initial,
    owner = self,
    key = subject,
    put_equal = true,
    remove_idempotent = true,
    apply = function(v, applied)
      self.holders[subject] = v
      self.versions[subject] = applied.version
      self.version = self.version + 1
    end,
  })
  self._locations[subject] = loc
  return loc
end

function Lease:acquire_op(subject, mode, owner)
  if subject == nil then
    error('lease acquire requires subject', 2)
  end
  if mode == nil then
    error('lease acquire requires mode', 2)
  end
  if owner == nil then
    error('lease acquire requires owner', 2)
  end
  local loc = self:_location(subject)
  return Op._resource(
    self,
    Kind,
    Program.admit({
      location = loc,
      group = loc,
      orientation = 'down', -- removing blockers supplies compatibility
      key = owner,
      value = mode,
      compatibility = self.compat,
      result_kind = 'constant',
      result_value = true,
    })
  )
end

function Lease:release_op(subject, owner)
  if subject == nil then
    error('lease release requires subject', 2)
  end
  if owner == nil then
    error('lease release requires owner', 2)
  end
  local loc = self:_location(subject)
  return Op._resource(
    self,
    Kind,
    Program.claim({
      location = loc,
      group = loc,
      orientation = 'up', -- presence is supplied by insertion; removal constrains
      predicate = 'map_present',
      key = owner,
      patch = { kind = 'finite_map', ops = { { op = 'remove', key = owner } } },
      result_kind = 'constant',
      result_value = true,
    })
  )
end

function Lease:snapshot_op()
  return Op._resource(self, Kind, Program.snapshot(self, 'lease'))
end

Lease.Kind = Kind
return Lease
