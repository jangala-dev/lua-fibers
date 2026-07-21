local Facility = require('fibers.internal.facility')
local Op = require('fibers.op')

local Counter = {}
Counter.__index = function(self, key)
  if key == 'value' then
    return self._location.value
  end
  if key == 'version' then
    return self._location.version
  end
  return Counter[key]
end
local Kind = Facility.kind('counter')

local function opt_number(opts, a, b)
  if type(opts) == 'number' then
    return opts
  end
  if type(opts) == 'table' then
    if opts[a] ~= nil then
      return opts[a]
    end
    if b and opts[b] ~= nil then
      return opts[b]
    end
  end
end

function Counter.new(opts, name)
  local initial, min, max
  if type(opts) == 'table' then
    initial = opt_number(opts, 'initial', 'value')
    min, max, name = opts.min, opts.max, opts.name or name
  else
    initial = opts
  end
  initial, min = initial == nil and 0 or initial, min == nil and 0 or min
  local counter = Facility.identity(setmetatable({ min = min, max = max }, Counter), Kind, name)
  counter._location = Facility.location(counter, 'stock', {
    algebra = 'add',
    domain = 'counter',
    value = initial,
  })
  counter._read_op = Facility.static(counter, Kind, 'read', {
    location = counter._location,
    result = Facility.result.value,
  })
  counter._state_op = Facility.static(counter, Kind, 'read', {
    location = counter._location,
    result = Facility.result.counter_state,
  })
  return counter
end

function Counter:adjust_op(n)
  if n == nil then
    error('counter adjust requires an amount', 2)
  end
  return Facility.static(self, Kind, 'patch', {
    location = self._location,
    patch = Facility.change.add(n),
    result = Facility.result.boolean,
  })
end
function Counter:add_op(n)
  if n == nil then
    error('counter add requires an amount', 2)
  end
  if n < 0 then
    error('counter add requires a non-negative amount; use adjust_op', 2)
  end
  return self:adjust_op(n)
end
function Counter:give_op(n)
  n = n or 1
  if n < 0 then
    error('counter give requires a non-negative amount', 2)
  end
  return self:adjust_op(n)
end
function Counter:take_op(n)
  n = n or 1
  if n < 0 then
    error('counter take requires a non-negative amount', 2)
  end
  if n == 0 then
    return Op.always(true)
  end
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self._location,
      demand = 'up',
      query = { kind = 'predicate', predicate = 'ge', threshold = (self.min or 0) + n },
      change = Facility.change.add(-n),
      result = Facility.result.boolean,
    })
  )
end
function Counter:read_op()
  return self._read_op
end
function Counter:state_op()
  return self._state_op
end

Counter.Kind = Kind
return Counter
