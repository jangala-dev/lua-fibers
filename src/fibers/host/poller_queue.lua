-- Persistent FIFO used by the HostPoller hot path.
--
-- External delivery conses onto an immutable back list in constant time.
-- Transactional dequeue reverses that list only when the front list is empty,
-- giving amortised constant-time queue service without copying every retained
-- readiness ticket.

local Op = require('fibers.op')
local Facility = require('fibers.internal.facility')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')

local PollerQueue = {}
PollerQueue.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return PollerQueue[key]
end

local Kind = Facility.kind('poller_ready_queue')
local unpack_ = table.unpack or unpack

local function clone_state(state)
  state = state or {}
  return {
    front = state.front,
    back = state.back,
    count = state.count or 0,
  }
end

local function reverse(list)
  local out = nil
  while list do
    out = { value = list.value, next = out }
    list = list.next
  end
  return out
end

local function normalise(state)
  if state.front == nil and state.back ~= nil then
    state.front = reverse(state.back)
    state.back = nil
  end
  return state
end

local function touch(queue, state)
  local location = queue._location
  location.value = state
  location.version = location.version + 1
end

local function deliver(queue, ...)
  local state = clone_state(queue._location.value)
  state.back = {
    value = Op._pack(...),
    next = state.back,
  }
  state.count = state.count + 1
  touch(queue, state)
end

local function clear(queue)
  touch(queue, { front = nil, back = nil, count = 0 })
end

function PollerQueue.new(name, opts)
  opts = opts or {}
  local queue = Facility.identity(
    setmetatable({
      _interest_factory = opts.interest,
    }, PollerQueue),
    Kind,
    name
  )

  queue._location = Facility.location(queue, 'queue', {
    algebra = 'machine',
    domain = 'external',
    value = { front = nil, back = nil, count = 0 },
    clone_value = clone_state,
  })
  queue._fibers_external_deliver = deliver
  queue._fibers_external_clear = clear
  queue._next_op = nil
  return queue
end

function PollerQueue:next_op()
  if self._next_op then
    return self._next_op
  end

  local transition = Scalar.transition({
    name = self.name .. ':next',
    mode = 'select',
    accepts_supply = false,
    supplies = 'none',
    step = function(state)
      if (state.count or 0) == 0 then
        return Scalar.Wait
      end
      local next_state = normalise(clone_state(state))
      local node = assert(next_state.front, 'poller queue count without front node')
      next_state.front = node.next
      next_state.count = next_state.count - 1
      local packed = node.value
      return Scalar.Ready.write(next_state, unpack_(packed, 1, packed.n))
    end,
  })

  self._next_op = Facility.op(
    self,
    Kind,
    Facility.machine(self._location, transition, {}, self, {
      interest = function(runtime)
        if type(self._interest_factory) == 'function' then
          return self._interest_factory(runtime, self, ExternalFeed.for_resource(runtime, self))
        end
        return Interest.external(self, 'next', {
          external_kind = 'poller',
          feed = ExternalFeed.for_resource(runtime, self),
        })
      end,
      absence_check = function()
        return (self._location.value.count or 0) == 0
      end,
    })
  )
  return self._next_op
end

function PollerQueue:length()
  return self._location.value.count or 0
end

PollerQueue.Kind = Kind
return PollerQueue
