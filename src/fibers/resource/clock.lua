local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local Interest = require('fibers.embed.external').Interest
local Direct = require('fibers.internal.direct')

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
  c._now_spec = Facility.clock_now(c)
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

local At = StateMachine.isolated_query('clock.at', function(_, deadline, context)
  local now = context.now()
  if now < deadline then
    return StateMachine.Wait
  end
  return StateMachine.Ready.same(now)
end)

function Clock:now_op()
  return Facility.op(self._now_spec)
end

function Clock:at_op(deadline)
  deadline = finite_number(deadline, 'Clock:at_op deadline')
  return Facility.external_wait(self, self._location, At, {
    payload = deadline,
    interest = Interest.timer(deadline, self),
    absence_check = function(rt)
      return rt:now() < deadline
    end,
  })
end

-- Relative time is explicit algebra over one activation-local observation.
function Clock:after_op(delay)
  delay = finite_number(delay, 'Clock:after_op delay')
  return self:now_op():and_then(Op.guard(function(now)
    return self:at_op(now + delay)
  end))
end

Clock.Kind = Kind
Direct.install(Clock, { 'now', 'at', 'after' })

return Clock
