local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local External = require('fibers.embed.external')
local Interest = External.Interest
local ExternalFeed = External.Feed
local Label = require('fibers.internal.label')

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
  if x ~= 'read' and x ~= 'write' then
    error('readiness mode must be read or write', level or 3)
  end
  return x
end

local function clone_state(s)
  return { read = not not s.read, write = not not s.write }
end
local function deliver(current, r, ...)
  local n, first = select('#', ...), ...
  local selected, value
  if type(first) == 'string' then
    selected, value = mode(first, 3), select(2, ...)
    if n <= 1 then value = true end
  else
    selected, value = mode(r.mode, 3), first
    if n == 0 then value = true end
  end
  local state = clone_state(current)
  state[selected] = value ~= false and value ~= nil
  return state
end

local function clear(current, _, selected)
  local state = clone_state(current)
  if selected == nil then
    state.read, state.write = false, false
  else
    state[mode(selected, 3)] = false
  end
  return state
end

function Readiness.new(key, initial_mode)
  local r = Facility.identity(
    setmetatable({
      key = key,
      mode = mode(initial_mode or 'read', 3),
    }, Readiness),
    Kind
  )
  r._location = Facility.location(r, {
    algebra = 'machine',
    domain = 'external',
    value = { read = false, write = false },
    clone_value = clone_state,
  })
  External.attach(r, r._location, deliver, clear)
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
  local transition = StateMachine.isolated_query(Label.describe(self, self._fibers_id or 'readiness') .. ':' .. selected, function(state)
    if not state[selected] then
      return StateMachine.Wait
    end
    return StateMachine.Ready.same(true, key, selected)
  end)
  local option = Facility.op(StateMachine._compile(self._location, self, transition, {
    wake = function(rt)
      return Interest.external(r, selected .. ':' .. tostring(key), {
        external_kind = 'readiness',
        readiness_key = key,
        mode = selected,
        feed = ExternalFeed.for_resource(rt, r),
      })
    end,
  }))
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
