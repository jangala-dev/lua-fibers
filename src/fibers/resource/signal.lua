local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local External = require('fibers.embed.external')
local Direct = require('fibers.internal.direct')

local Signal = {}
Signal.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return Signal[key]
end

local Kind = Facility.kind('signal')
local unpack_ = table.unpack or unpack

local Wait = StateMachine.isolated_query('signal.wait', function(state)
  if not state.ready then
    return StateMachine.Wait
  end
  return StateMachine.Ready.same(unpack_(state.values, 1, state.values.n))
end)

local function deliver(signal, ...)
  Facility.publish(signal._location, { ready = true, values = Values.pack(...) })
end

local function clear(signal)
  Facility.publish(signal._location, { ready = false })
end

function Signal.new(name)
  local signal = Facility.identity(setmetatable({}, Signal), Kind, name)
  signal._location = Facility.location(signal, 'state', {
    algebra = 'machine',
    domain = 'external',
    value = { ready = false },
    clone_value = function(state)
      return { ready = state.ready, values = state.values }
    end,
  })
  signal._fibers_external_deliver = deliver
  signal._fibers_external_clear = clear
  signal._wait_op = Facility.external_wait(signal, signal._location, Wait, {
    interest = function(runtime)
      return External.Interest.external(signal, 'ready', {
        external_kind = 'signal',
        feed = External.Feed.for_resource(runtime, signal),
      })
    end,
    absence_check = function()
      return not signal._location.value.ready
    end,
  })
  return signal
end

function Signal:wait_op()
  return self._wait_op
end

Direct.install(Signal, { 'wait' })

Signal.Kind = Kind

return Signal
