local Op = require('fibers.atoms.op')
local Scalar = require('fibers.atoms.scalar')
local Interest = require('fibers.interest')
local Substrate = require('fibers.kernel.store')

local Clock = {}
Clock.__index = Clock
local Kind = { name = 'clock' }
local next_id = 0

function Clock.new(name)
  next_id = next_id + 1
  local c = setmetatable({
    name = name or ('clock-' .. tostring(next_id)),
    _fibers_id = 'clock-' .. tostring(next_id),
    _fibers_kind = Kind,
  }, Clock)
  c._location = Substrate.new_location({
    name = c.name .. ':observation',
    merge = 'machine',
    domain = 'external-clock',
    value = false,
    owner = c,
  })
  return c
end

function Clock:at_op(deadline)
  local transition = Scalar.transition({
    name = self.name .. ':at',
    mode = 'query',
    supply = 'none',
    step = function(_, _, ctx)
      local now = ctx.now()
      if now < deadline then
        return Scalar.Wait
      end
      return Scalar.Ready.same(true, now)
    end,
  })
  return Op._compact_resource(self, Kind, 'machine_transition', {
    location = self._location,
    resource = self,
    transition = transition,
    order = transition.order or 0,
    interest = Interest.timer(deadline, self),
    absence_check = function(rt)
      return rt:now() < deadline
    end,
  })
end
Clock.Kind = Kind
return Clock
