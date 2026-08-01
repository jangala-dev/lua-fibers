-- Externally fed persistent FIFO.

local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local External = require('fibers.embed.external')
local Direct = require('fibers.internal.direct')

local EventQueue = {}
EventQueue.__index = function(self, key)
  if key == 'version' then return self._location.version end
  return EventQueue[key]
end

local Kind = Facility.kind('event_queue')
local unpack_ = table.unpack or unpack

local function clone(state)
  return { front = state.front, back = state.back, count = state.count, head = state.head }
end

local function reverse(list)
  local reversed
  while list do
    reversed = { value = list.value, next = reversed }
    list = list.next
  end
  return reversed
end

local function normalise(state)
  if not state.front and state.back then
    state.front, state.back = reverse(state.back), nil
  end
end

local function deliver(state, _, ...)
  local node = { value = Facility.pack(...) }
  if state.count == 0 then
    return { front = node, count = 1, head = state.head }
  end
  node.next = state.back
  return {
    front = state.front,
    back = node,
    count = state.count + 1,
    head = state.head,
  }
end

local function clear(state)
  return { count = 0, head = state.head }
end

local Next = StateMachine.isolated_select('event_queue.next', function(current)
  if current.count == 0 then return StateMachine.Wait end
  local state = clone(current)
  normalise(state)
  local node = assert(state.front, 'event queue count without front node')
  state.front = node.next
  state.count = state.count - 1
  state.head = state.head + 1
  return StateMachine.Ready.write(state, unpack_(node.value, 1, node.value.n))
end)

local Drain = StateMachine.isolated_select('event_queue.drain', function(current)
  if current.count == 0 then return StateMachine.Wait end
  local state, values = clone(current), {}
  normalise(state)
  local node = state.front
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
  return StateMachine.Ready.write(state, values)
end)

local function interest(queue, runtime)
  local feed = External.Feed.for_resource(runtime, queue)
  if queue._interest_factory then
    return queue._interest_factory(runtime, queue, feed)
  end
  return External.Interest.external(queue, 'next', {
    external_kind = 'events',
    feed = feed,
  })
end

local function option(queue, transition)
  return Facility.op(StateMachine._compile(queue._location, queue, transition, {
    wake = function(runtime) return interest(queue, runtime) end,
  }))
end

function EventQueue.new(name, interest_factory)
  local queue = Facility.identity(setmetatable({ _interest_factory = interest_factory }, EventQueue), Kind, name)
  queue._location = Facility.location(queue, 'queue', {
    algebra = 'machine',
    domain = 'external',
    value = { count = 0, head = 1 },
    clone_value = clone,
  })
  External.attach(queue, queue._location, deliver, clear)
  queue._next_op = option(queue, Next)
  queue._drain_cached_op = option(queue, Drain)
  return queue
end

function EventQueue:next_op()
  return self._next_op
end


function EventQueue:_drain_op()
  return self._drain_cached_op
end

function EventQueue:length()
  return self._location.value.count
end

Direct.install(EventQueue, { 'next' })

EventQueue.Kind = Kind

return EventQueue
