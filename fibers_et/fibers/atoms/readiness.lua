local Op = require('fibers.atoms.op')
local Scalar = require('fibers.atoms.scalar')
local Program = require('fibers.kernel.ir')
local Interest = require('fibers.interest')
local ExternalFeed = require('fibers.external_feed')
local Substrate = require('fibers.kernel.store')

local Readiness = {}
Readiness.__index = Readiness
local Kind = { name = 'readiness' }
local next_id = 0

local function mode(x, level)
  x = x or 'read'
  if x == 'wr' then x = 'write' end
  if x ~= 'read' and x ~= 'write' then error('readiness mode must be read or write', level or 3) end
  return x
end

local function clone_state(s) return { read = not not s.read, write = not not s.write } end
local function touch(r, state)
  local loc = r._location
  loc.value = state
  loc.version = loc.version + 1
  r.version = loc.version
end
local function deliver(r, ...)
  local n, first = select('#', ...), ...
  local selected, value
  if type(first) == 'string' then
    selected, value = mode(first, 3), select(2, ...)
    if n <= 1 then value = true end
  else
    selected, value = mode(r.mode, 3), first
    if n == 0 then value = true end
  end
  local state = clone_state(r._location.value)
  state[selected] = value ~= false and value ~= nil
  touch(r, state)
end
local function clear(r, selected)
  local state = clone_state(r._location.value)
  if selected == nil then state.read, state.write = false, false
  else state[mode(selected, 3)] = false end
  touch(r, state)
end

function Readiness.new(key, initial_mode, name)
  next_id = next_id + 1
  local r = setmetatable({
    key = key, mode = mode(initial_mode or 'read', 3),
    name = name or ('readiness-' .. tostring(next_id)),
    _fibers_id = 'readiness-' .. tostring(next_id), _fibers_kind = Kind, version = 0,
  }, Readiness)
  r._location = Substrate.new_location({
    name = r.name .. ':state', merge = 'machine', domain = 'external',
    value = { read = false, write = false }, owner = r, clone_value = clone_state,
    apply = function(v, loc) r.version = loc.version end,
  })
  r._fibers_external_deliver = deliver
  r._fibers_external_clear = clear
  return r
end

function Readiness:readiness_op(selected)
  selected = mode(selected or self.mode, 3)
  local r, key = self, self.key
  local transition = Scalar.transition({
    name = self.name .. ':' .. selected, mode = 'query', supply = 'none',
    step = function(state)
      if not state[selected] then return Scalar.Wait end
      return Scalar.Ready.same(true, key, selected)
    end,
  })
  return Op._resource(self, Kind, Program.machine_transition({
    location = self._location, resource = self, transition = transition,
    interest = function(rt)
      return Interest.external(r, selected .. ':' .. tostring(key), {
        external_kind = 'readiness', key = key, resource_key = key,
        readiness_key = key, mode = selected, feed = ExternalFeed.for_resource(rt, r),
      })
    end,
    absence_check = function() return not r._location.value[selected] end,
  }))
end
function Readiness:wait_op() return self:readiness_op(self.mode) end
function Readiness:readable_op() return self:readiness_op('read') end
function Readiness:writable_op() return self:readiness_op('write') end
Readiness.Kind = Kind
return Readiness
