local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Scalar = require('fibers.resource.scalar')
local Interest = require('fibers.host.external').Interest

local Clock = {}
Clock.__index = Clock
local Kind = Facility.kind('clock')
local default_clock

local function finite_number(value, name)
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    error(name .. ' must be a finite number', 3)
  end
  return value
end

function Clock.new(name)
  local c = Facility.identity(setmetatable({}, Clock), Kind, name)
  c._location = Facility.location(c, 'observation', {
    algebra = 'machine',
    domain = 'external-clock',
    value = false,
  })
  return c
end

-- The default monotonic clock used by the sleep vocabulary and facilities which
-- do not need an explicitly injected clock.
function Clock.default()
  if not default_clock then
    default_clock = Clock.new('default-clock')
  end
  return default_clock
end

local Now = Scalar.transition({
  name = 'clock.now',
  mode = 'query',
  accepts_supply = false,
  supplies = 'none',
  step = function(_, _, ctx)
    return Scalar.Ready.same(ctx.now())
  end,
})

local At = Scalar.transition({
  name = 'clock.at',
  mode = 'query',
  accepts_supply = false,
  supplies = 'none',
  step = function(_, payload, ctx)
    local now = ctx.now()
    if now < payload.deadline then
      return Scalar.Wait
    end
    return Scalar.Ready.same(now)
  end,
})

function Clock:now_op()
  return Facility.external_wait(self, Kind, self._location, Now)
end

function Clock:at_op(deadline)
  deadline = finite_number(deadline, 'Clock:at_op deadline')
  return Facility.external_wait(self, Kind, self._location, At, {
    payload = { deadline = deadline },
    interest = Interest.timer(deadline, self),
    absence_check = function(rt)
      return rt:now() < deadline
    end,
  })
end

-- Relative time is surface syntax. Each guard activation takes one stable
-- activation-time observation and elaborates to an explicit absolute wait.
function Clock:after_op(delay)
  delay = finite_number(delay, 'Clock:after_op delay')
  return Op.guard(function(activation)
    return self:at_op(activation:now() + delay)
  end)
end

Facility.performing(Clock, { 'now', 'at', 'after' })
Clock.Kind = Kind
return Clock
