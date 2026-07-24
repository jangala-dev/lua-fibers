-- Externally fed persistent FIFO.
--
-- Arrivals are consed onto a back list and reversed only when the front list is
-- exhausted.  Delivery, transactional cloning and single-item removal are
-- therefore O(1) amortised and do not copy the queued payloads.

local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Scalar = require('fibers.resource.scalar')
local Interest = require('fibers.host.external').Interest
local ExternalFeed = require('fibers.host.external').Feed

local EventQueue = {}
EventQueue.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return EventQueue[key]
end
local Kind = Facility.kind('event_queue')
local unpack_ = table.unpack or unpack

local function clone_state(state)
  return { front = state.front, back = state.back, count = state.count, head = state.head }
end

local function reverse(list)
  local out
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

local function deliver(queue, ...)
  local current = queue._location.value
  local node = { value = Op._pack(...) }
  if current.count == 0 then
    Facility.publish(queue._location, { front = node, count = 1, head = current.head })
  else
    node.next = current.back
    Facility.publish(queue._location, {
      front = current.front,
      back = node,
      count = current.count + 1,
      head = current.head,
    })
  end
end

local function clear(queue)
  Facility.publish(queue._location, { count = 0, head = queue._location.value.head })
end

function EventQueue.new(name, opts)
  opts = opts or {}
  local queue = Facility.identity(setmetatable({ _interest_factory = opts.interest }, EventQueue), Kind, name)
  queue._location = Facility.location(queue, 'queue', {
    algebra = 'machine',
    domain = 'external',
    value = { count = 0, head = 1 },
    clone_value = clone_state,
  })
  queue._fibers_external_deliver = deliver
  queue._fibers_external_clear = clear
  queue._next_op = false
  queue._drain_cached_op = false
  return queue
end

local function interest_for(queue, runtime)
  local feed = ExternalFeed.for_resource(runtime, queue)
  if type(queue._interest_factory) == 'function' then
    return queue._interest_factory(runtime, queue, feed)
  end
  return Interest.external(queue, 'next', {
    external_kind = 'events',
    feed = feed,
  })
end

local function drain_values(state)
  local values, node = {}, state.front
  while node do
    values[#values + 1] = node.value
    node = node.next
  end
  node = reverse(state.back)
  while node do
    values[#values + 1] = node.value
    node = node.next
  end
  state.front, state.back = nil, nil
  state.head = state.head + state.count
  state.count = 0
  return values
end

local function op_for(queue, drain)
  local transition = Scalar.transition({
    name = queue.name .. (drain and ':drain' or ':next'),
    mode = 'select',
    accepts_supply = false,
    supplies = 'none',
    step = function(current)
      if current.count == 0 then
        return Scalar.Wait
      end
      local state = clone_state(current)
      if drain then
        return Scalar.Ready.write(state, drain_values(state))
      end
      normalise(state)
      local node = assert(state.front, 'event queue count without front node')
      state.front = node.next
      state.count = state.count - 1
      state.head = state.head + 1
      local packed = node.value
      return Scalar.Ready.write(state, unpack_(packed, 1, packed.n))
    end,
  })
  return Facility.external_wait(queue, Kind, queue._location, transition, {
    interest = function(runtime)
      return interest_for(queue, runtime)
    end,
    absence_check = function()
      return queue._location.value.count == 0
    end,
  })
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

function EventQueue:length()
  return self._location.value.count
end

EventQueue.Kind = Kind
return EventQueue
