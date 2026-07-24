local Facility = require('fibers.resource.authoring')
local Scalar = require('fibers.resource.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')

local Readiness = {}
Readiness.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return Readiness[key]
end
local Kind = Facility.kind('readiness')

local function mode(x, level)
  x = x or 'read'
  if x == 'wr' then
    x = 'write'
  end
  if x ~= 'read' and x ~= 'write' then
    error('readiness mode must be read or write', level or 3)
  end
  return x
end

local function clone_state(s)
  return { read = not not s.read, write = not not s.write }
end
local function deliver(r, ...)
  local n, first = select('#', ...), ...
  local selected, value
  if type(first) == 'string' then
    selected, value = mode(first, 3), select(2, ...)
    if n <= 1 then
      value = true
    end
  else
    selected, value = mode(r.mode, 3), first
    if n == 0 then
      value = true
    end
  end
  local state = clone_state(r._location.value)
  state[selected] = value ~= false and value ~= nil
  Facility.publish(r._location, state)
end
local function clear(r, selected)
  local state = clone_state(r._location.value)
  if selected == nil then
    state.read, state.write = false, false
  else
    state[mode(selected, 3)] = false
  end
  Facility.publish(r._location, state)
end

function Readiness.new(key, initial_mode, name)
  local r = Facility.identity(
    setmetatable({
      key = key,
      mode = mode(initial_mode or 'read', 3),
    }, Readiness),
    Kind,
    name
  )
  r._location = Facility.location(r, 'state', {
    algebra = 'machine',
    domain = 'external',
    value = { read = false, write = false },
    clone_value = clone_state,
  })
  r._fibers_external_deliver = deliver
  r._fibers_external_clear = clear
  r._read_op, r._write_op = false, false
  return r
end

function Readiness:readiness_op(selected)
  selected = mode(selected or self.mode, 3)
  local field = selected == 'read' and '_read_op' or '_write_op'
  if self[field] ~= false then
    return self[field]
  end
  local r, key = self, self.key
  local transition = Scalar.transition({
    name = self.name .. ':' .. selected,
    mode = 'query',
    accepts_supply = false,
    supplies = 'none',
    step = function(state)
      if not state[selected] then
        return Scalar.Wait
      end
      return Scalar.Ready.same(true, key, selected)
    end,
  })
  local option = Facility.external_wait(self, Kind, self._location, transition, {
    interest = function(rt)
      return Interest.external(r, selected .. ':' .. tostring(key), {
        external_kind = 'readiness',
        key = key,
        resource_key = key,
        readiness_key = key,
        mode = selected,
        feed = ExternalFeed.for_resource(rt, r),
      })
    end,
    absence_check = function()
      return not r._location.value[selected]
    end,
  })
  self[field] = option
  return option
end
function Readiness:wait_op()
  return self:readiness_op(self.mode)
end
function Readiness:readable_op()
  return self:readiness_op('read')
end
function Readiness:writable_op()
  return self:readiness_op('write')
end
Readiness.Kind = Kind
return Readiness
