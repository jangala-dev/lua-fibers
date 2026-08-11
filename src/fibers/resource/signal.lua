local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local External = require('fibers.embed.external')
local Direct = require('fibers.internal.direct')

local Signal = {}
Signal.__index = Signal

local Kind = Facility.kind('signal')

local Wait = StateMachine.isolated_query('signal.wait', function(state)
  if not state.ready then return StateMachine.Wait end
  return StateMachine.Ready.same(Facility.unpack(state.values, 1, state.values.n))
end)

local function deliver(_, _, ...)
  return { ready = true, values = Facility.pack(...) }
end

local function clear()
  return { ready = false }
end

local function clone(state)
  return { ready = state.ready, values = state.values }
end

local function wake(runtime, leaf)
  local signal = leaf.resource
  return External.Interest.external(signal, 'ready', {
    external_kind = 'signal', feed = External.Feed.for_resource(runtime, signal),
  })
end

function Signal.new()
  local signal = Facility.identity(setmetatable({}, Signal), Kind)
  External._machine(signal, { ready = false }, clone, deliver, clear)
  signal._wait_op = External._op(signal, Wait, wake)
  return signal
end

function Signal:wait_op()
  return self._wait_op
end

Direct.install(Signal, { 'wait' })

Signal.Kind = Kind

return Signal
