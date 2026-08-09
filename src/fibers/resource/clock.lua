local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
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

local function wake(runtime, leaf, deadline)
  return Interest.timer(deadline, leaf.resource)
end

local function absent(runtime, deadline)
  return runtime:now() < deadline
end

local function at(_, deadline, context)
  local now = context.now()
  if now >= deadline then return Facility.outcome(nil, now) end
end

function Clock.new()
  local c = Facility.identity(setmetatable({}, Clock), Kind)
  c._location = Facility.location(c, {
    algebra = 'machine',
    domain = 'external-clock',
    value = false,
  })
  c._now_spec = Facility.clock_now(c)
  return c
end

function Clock.default()
  if not default_clock then default_clock = Clock.new():label('default-clock') end
  return default_clock
end

function Clock:now_op()
  return Facility.op(self._now_spec)
end

function Clock:at_op(deadline)
  finite_number(deadline, 'Clock:at_op deadline')
  local spec = self._at_spec
  if not spec then
    spec = Facility._state_rule('inspect', {
      location = self._location, resource = self, wake = wake, visibility = 'own', step = at,
    }, { absence_check = absent })
    self._at_spec = spec
  end
  return Facility.bind(spec, deadline)
end

function Clock:after_op(delay)
  delay = finite_number(delay, 'Clock:after_op delay')
  return self:now_op():and_then(Op.guard(function(now)
    return self:at_op(now + delay)
  end))
end

Clock.Kind = Kind
Direct.install(Clock, { 'now', 'at', 'after' })

return Clock
