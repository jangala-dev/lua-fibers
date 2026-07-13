local Op = require('fibers.atoms.op')
local Substrate = require('fibers.kernel.store')
local Program = require('fibers.kernel.ir')

local Keyed = {}
Keyed.__index = Keyed
local Kind = { name = 'keyed' }
local next_id = 0
local ABSENT = Substrate.ABSENT
local NIL = {}
local function enc(v)
  return v == nil and NIL or v
end

function Keyed.new(entries, name)
  next_id = next_id + 1
  local map = setmetatable({
    entries = {},
    versions = {},
    version = 0,
    name = name or ('keyed-' .. tostring(next_id)),
    _fibers_id = 'keyed-' .. tostring(next_id),
    _fibers_kind = Kind,
    _locations = {},
    _nil_sentinel = NIL,
  }, Keyed)
  for k, v in pairs(entries or {}) do
    map.entries[k] = enc(v)
    map.versions[k] = 0
  end
  return map
end

function Keyed:_location(key)
  local loc = self._locations[key]
  if loc then
    return loc
  end
  local initial = self.entries[key]
  if initial == nil then
    initial = ABSENT
  end
  loc = Substrate.new_location({
    name = self.name .. ':' .. tostring(key),
    merge = 'presence',
    domain = 'presence',
    value = initial,
    owner = self,
    key = key,
    apply = function(v, applied)
      if v == ABSENT then
        self.entries[key] = nil
      else
        self.entries[key] = v
      end
      self.versions[key] = applied.version
      self.version = self.version + 1
    end,
  })
  self._locations[key] = loc
  return loc
end

local function result_opts(map)
  return { nil_sentinel = map._nil_sentinel }
end
function Keyed:get_op(key)
  if key == nil then
    error('keyed get requires key', 2)
  end
  local loc = self:_location(key)
  return Op._resource(
    self,
    Kind,
    Program.claim({
      location = loc,
      group = self,
      orientation = 'up',
      predicate = 'present',
      result_kind = 'presence_value',
      nil_sentinel = self._nil_sentinel,
    })
  )
end
function Keyed:peek_op(key)
  if key == nil then
    error('keyed peek requires key', 2)
  end
  return Op._resource(
    self,
    Kind,
    Program.read(self:_location(key), 'presence_value', result_opts(self))
  )
end
function Keyed:contains_op(key)
  if key == nil then
    error('keyed contains requires key', 2)
  end
  return Op._resource(self, Kind, Program.read(self:_location(key), 'presence_bool'))
end
function Keyed:put_op(key, value)
  if key == nil then
    error('keyed put requires key', 2)
  end
  return Op._resource(
    self,
    Kind,
    Program.patch(
      self:_location(key),
      { kind = 'presence', ops = { { op = 'put', value = enc(value) } } },
      'constant',
      true
    )
  )
end
function Keyed:put_absent_op(key, value)
  if key == nil then
    error('keyed put_absent requires key', 2)
  end
  local loc = self:_location(key)
  return Op._resource(
    self,
    Kind,
    Program.claim({
      location = loc,
      group = self,
      orientation = 'down',
      predicate = 'absent',
      patch = { kind = 'presence', ops = { { op = 'put', value = enc(value) } } },
      result_kind = 'constant',
      result_value = true,
    })
  )
end
function Keyed:remove_op(key)
  if key == nil then
    error('keyed remove requires key', 2)
  end
  local loc = self:_location(key)
  return Op._resource(
    self,
    Kind,
    Program.conditional_claim({
      location = loc,
      group = self,
      orientation = 'up',
      predicate = 'present',
      immediate_patch = { kind = 'presence', ops = { { op = 'remove' } } },
      claim_patch = { kind = 'presence', ops = { { op = 'take' } } },
      result_kind = 'constant',
      result_value = true,
    })
  )
end
function Keyed:remove_present_op(key)
  if key == nil then
    error('keyed remove_present requires key', 2)
  end
  local loc = self:_location(key)
  return Op._resource(
    self,
    Kind,
    Program.claim({
      location = loc,
      group = self,
      orientation = 'up',
      predicate = 'present',
      patch = { kind = 'presence', ops = { { op = 'take' } } },
      result_kind = 'presence_value',
      nil_sentinel = self._nil_sentinel,
    })
  )
end
function Keyed:snapshot_op()
  return Op._resource(self, Kind, Program.snapshot(self, 'keyed'))
end

Keyed.Kind = Kind
Keyed.ABSENT = ABSENT
return Keyed
