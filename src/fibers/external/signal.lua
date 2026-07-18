local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')

local Signal = {}
Signal.__index = Signal
local Kind = { name = 'signal' }
local next_id = 0
local unpack_ = table.unpack or unpack

local function clone_state(s)
  return { ready = s.ready, pack = s.pack }
end

local function touch(signal, state)
  local loc = signal._location
  loc.value = state
  loc.version = loc.version + 1
  signal.version = loc.version
end

local function deliver(signal, ...)
  touch(signal, { ready = true, pack = Op._pack(...) })
end

local function clear(signal)
  touch(signal, { ready = false, pack = nil })
end

function Signal.new(name)
  next_id = next_id + 1
  local signal = setmetatable({
    name = name or ('signal-' .. tostring(next_id)),
    _fibers_id = 'signal-' .. tostring(next_id),
    _fibers_kind = Kind,
    version = 0,
  }, Signal)
  signal._location = require('fibers.internal.kernel.store').new_location({
    name = signal.name .. ':state',
    merge = 'machine',
    domain = 'external',
    value = { ready = false, pack = nil },
    owner = signal,
    clone_value = clone_state,
    apply = function(v, loc)
      signal.version = loc.version
    end,
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
  self._wait_op = Op._compact_resource(self, Kind, 'machine_transition', {
    location = self._location,
    resource = self,
    transition = transition,
    order = transition.order or 0,
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
  return self._wait_op
end

Signal.Kind = Kind
return Signal
