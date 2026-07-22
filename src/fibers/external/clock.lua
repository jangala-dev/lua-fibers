local Facility = require('fibers.internal.facility')
local Scalar = require('fibers.scalar')
local Interest = require('fibers.external.interest')

local Clock = {}
Clock.__index = Clock
local Kind = Facility.kind('clock')

function Clock.new(name)
  local c = Facility.identity(setmetatable({}, Clock), Kind, name)
  c._location = Facility.location(c, 'observation', {
    algebra = 'machine',
    domain = 'external-clock',
    value = false,
  })
  return c
end

function Clock:at_op(deadline)
  local transition = Scalar.transition({
    name = self.name .. ':at',
    mode = 'query',
    accepts_supply = false,
    supplies = 'none',
    step = function(_, _, ctx)
      local now = ctx.now()
      if now < deadline then
        return Scalar.Wait
      end
      return Scalar.Ready.same(true, now)
    end,
  })
  return Facility.external_wait(self, Kind, self._location, transition, {
    interest = Interest.timer(deadline, self),
    absence_check = function(rt)
      return rt:now() < deadline
    end,
  })
end
Clock.Kind = Kind
return Clock
