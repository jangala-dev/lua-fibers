local Op = require('fibers.op')
local Facility = require('fibers.internal.facility')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')

local Signal = {}
Signal.__index = function(self, key)
  if key == 'version' then
    return self._location.version
  end
  return Signal[key]
end
local Kind = Facility.kind('signal')
local unpack_ = table.unpack or unpack

local function clone_state(s)
  return { ready = s.ready, pack = s.pack }
end

local function touch(signal, state)
  local loc = signal._location
  loc.value = state
  loc.version = loc.version + 1
end

local function deliver(signal, ...)
  touch(signal, { ready = true, pack = Op._pack(...) })
end

local function clear(signal)
  touch(signal, { ready = false, pack = nil })
end

function Signal.new(name)
  local signal = Facility.identity(setmetatable({}, Signal), Kind, name)
  signal._location = Facility.location(signal, 'state', {
    algebra = 'machine',
    domain = 'external',
    value = { ready = false, pack = nil },
    clone_value = clone_state,
    apply = function(v, loc) end,
  })
  signal._fibers_external_deliver = deliver
  signal._fibers_external_clear = clear
  signal._wait_op = false
  return signal
end

function Signal:wait_op()
  if self._wait_op ~= false then
    return self._wait_op
  end
  local signal = self
  local transition = Scalar.transition({
    name = self.name .. ':wait',
    mode = 'query',
    accepts_supply = false,
    supplies = 'none',
    step = function(state)
      if not state.ready then
        return Scalar.Wait
      end
      return Scalar.Ready.same(unpack_(state.pack, 1, state.pack.n))
    end,
  })
  self._wait_op = Facility.op(
    self,
    Kind,
    Facility.machine(self._location, transition, {}, self, {
      interest = function(rt)
        return Interest.external(signal, 'ready', {
          external_kind = 'signal',
          feed = ExternalFeed.for_resource(rt, signal),
        })
      end,
      absence_check = function()
        return not signal._location.value.ready
      end,
    })
  )
  return self._wait_op
end

Signal.Kind = Kind
return Signal
