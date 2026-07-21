local Op = require('fibers.op')
local IR = require('fibers.internal.kernel.ir')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')
local Substrate = require('fibers.internal.kernel.ledger')

local EventQueue = {}
EventQueue.__index = EventQueue
local Kind = { name = 'event_queue' }
local next_id = 0
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
  q.version = loc.version
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
  next_id = next_id + 1
  local q = setmetatable({
    name = name or ('events-' .. tostring(next_id)),
    _fibers_id = 'events-' .. tostring(next_id),
    _fibers_kind = Kind,
    version = 0,
    _interest_factory = opts.interest,
  }, EventQueue)
  q._location = Substrate.new_location({
    name = q.name .. ':queue',
    algebra = 'machine',
    domain = 'external',
    value = { head = 1, values = {} },
    owner = q,
    clone_value = clone_state,
    apply = function(v, loc)
      q.version = loc.version
    end,
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
  return Op._compact_resource(
    q,
    Kind,
    'transition',
    IR.machine_transition({
      location = q._location,
      resource = q,
      transition = transition,
      order = transition.order or 0,
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
