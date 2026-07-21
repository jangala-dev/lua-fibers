local Op = require('fibers.op')
local Facility = require('fibers.internal.facility')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')

local EventQueue = {}
EventQueue.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return EventQueue[key]
end
local Kind = Facility.kind('event_queue')
local unpack_ = table.unpack or unpack

local function clone_state(s)
  local out = { head = s.head or 1, values = {} }
  for i = 1, #(s.values or {}) do
    out.values[i] = s.values[i]
  end
  return out
end
local function touch(q, state)
  local loc = q._location
  loc.value = state
  loc.version = loc.version + 1
end
local function deliver(q, ...)
  local state = clone_state(q._location.value)
  state.values[#state.values + 1] = Op._pack(...)
  touch(q, state)
end
local function clear(q)
  touch(q, { head = 1, values = {} })
end

function EventQueue.new(name, opts)
  opts = opts or {}
  local q = Facility.identity(
    setmetatable({
      _interest_factory = opts.interest,
    }, EventQueue),
    Kind,
    name
  )
  q._location = Facility.location(q, 'queue', {
    algebra = 'machine',
    domain = 'external',
    value = { head = 1, values = {} },
    clone_value = clone_state,
    apply = function(v, loc) end,
  })
  q._fibers_external_deliver = deliver
  q._fibers_external_clear = clear
  q._next_op = false
  q._drain_cached_op = false
  return q
end

local function op_for(q, drain)
  local transition = Scalar.transition({
    name = q.name .. (drain and ':drain' or ':next'),
    mode = 'select',
    accepts_supply = false,
    supplies = 'none',
    step = function(state)
      local n = #state.values
      if n == 0 then
        return Scalar.Wait
      end
      local next_state = clone_state(state)
      if drain then
        local values = {}
        for i = 1, n do
          values[i] = next_state.values[i]
        end
        next_state.values = {}
        next_state.head = next_state.head + n
        return Scalar.Ready.write(next_state, values)
      end
      local packed = table.remove(next_state.values, 1)
      next_state.head = next_state.head + 1
      return Scalar.Ready.write(next_state, unpack_(packed, 1, packed.n))
    end,
  })
  return Facility.op(
    q,
    Kind,
    Facility.machine(q._location, transition, {}, q, {
      interest = function(rt)
        if type(q._interest_factory) == 'function' then
          return q._interest_factory(rt, q, ExternalFeed.for_resource(rt, q))
        end
        return Interest.external(q, 'next', {
          external_kind = 'events',
          feed = ExternalFeed.for_resource(rt, q),
        })
      end,
      absence_check = function()
        return #q._location.value.values == 0
      end,
    })
  )
end
function EventQueue:next_op()
  if self._next_op == false then
    self._next_op = op_for(self, false)
  end
  return self._next_op
end
function EventQueue:_drain_op()
  if self._drain_cached_op == false then
    self._drain_cached_op = op_for(self, true)
  end
  return self._drain_cached_op
end
EventQueue.Kind = Kind
return EventQueue
