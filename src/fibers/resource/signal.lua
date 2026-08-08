local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local External = require('fibers.embed.external')
local Direct = require('fibers.internal.direct')

local Signal = {}
Signal.__index = function(self, key)
  if key == 'version' then return self._location.version end
  return Signal[key]
end

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

function Signal.new()
  local signal = Facility.identity(setmetatable({}, Signal), Kind)
  signal._location = Facility.location(signal, {
    algebra = 'machine',
    domain = 'external',
    value = { ready = false },
    clone_value = function(state)
      return { ready = state.ready, values = state.values }
    end,
  })
  External.attach(signal, signal._location, deliver, clear)
  signal._wait_op = Facility.op(StateMachine._compile(signal._location, signal, Wait, {
    wake = function(runtime)
      return External.Interest.external(signal, 'ready', {
        external_kind = 'signal',
        feed = External.Feed.for_resource(runtime, signal),
      })
    end,
  }))
  return signal
end

function Signal:wait_op()
  return self._wait_op
end

Direct.install(Signal, { 'wait' })

Signal.Kind = Kind

return Signal
