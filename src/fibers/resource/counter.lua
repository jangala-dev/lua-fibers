local Facility = require('fibers.resource.authoring')
local perform = require('fibers.perform')
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

local function integer(value, label, level)
  if type(value) ~= 'number' or value % 1 ~= 0 then
    error(label .. ' must be an integer', level or 3)
  end
  return value
end

local function create(initial, minimum, maximum, name)
  integer(initial, 'counter initial value', 3)
  integer(minimum, 'counter minimum', 3)
  if maximum ~= nil then
    integer(maximum, 'counter maximum', 3)
  end
  if initial < minimum or maximum and initial > maximum then
    error('counter initial value is outside its range', 3)
  end
  if maximum and minimum > maximum then
    error('counter minimum must not exceed maximum', 3)
  end

  local counter = Facility.identity(setmetatable({ min = minimum, max = maximum }, Counter), Kind, name)
  counter._location = Facility.location(counter, 'value', {
    algebra = 'add',
    domain = 'counter',
    value = initial,
  })
  counter._read_op = Facility.static(counter, Kind, 'read', {
    location = counter._location,
    result = Facility.result.value,
  })
  counter._changed_descriptor = Facility.descriptor(counter, Kind, 'version_wait', {
    location = counter._location,
    bind = 'version',
  })
  return counter
end

function Counter.new(initial, name)
  return create(initial or 0, 0, nil, name)
end

function Counter.bounded(capacity, name)
  integer(capacity, 'counter capacity', 2)
  if capacity < 0 then
    error('counter capacity must be non-negative', 2)
  end
  return create(capacity, 0, capacity, name)
end

function Counter.range(initial, minimum, maximum, name)
  return create(initial, minimum, maximum, name)
end

function Counter:read_op()
  return self._read_op
end

function Counter:read()
  return perform(self:read_op())
end

function Counter:changed_op(version)
  return Facility.occurrence(self._changed_descriptor, version)
end

function Counter:changed(version)
  return perform(self:changed_op(version))
end

function Counter:adjust_op(amount)
  integer(amount, 'counter adjustment', 2)
  if amount == 0 then
    return Op.always(self.value)
  end
  return Facility.static(self, Kind, 'patch', {
    location = self._location,
    patch = Facility.change.add(amount),
    result = Facility.result.boolean,
  })
end

function Counter:adjust(amount)
  return perform(self:adjust_op(amount))
end

function Counter:add_op(amount)
  integer(amount, 'counter addition', 2)
  if amount < 0 then
    error('counter addition must be non-negative', 2)
  end
  return self:adjust_op(amount)
end

function Counter:add(amount)
  return perform(self:add_op(amount))
end

function Counter:bump_op()
  return Facility.static(self, Kind, 'patch', {
    location = self._location,
    patch = Facility.change.add(1),
    result = Facility.result.value,
  })
end

function Counter:bump()
  return perform(self:bump_op())
end

function Counter:give_op(amount)
  return self:add_op(amount or 1)
end

function Counter:give(amount)
  return perform(self:give_op(amount))
end

function Counter:take_op(amount)
  amount = amount or 1
  integer(amount, 'counter take', 2)
  if amount < 0 then
    error('counter take must be non-negative', 2)
  end
  if amount == 0 then
    return Op.always(self.value)
  end
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self._location,
      demand = 'up',
      query = { kind = 'predicate', predicate = 'ge', threshold = self.min + amount },
      change = Facility.change.add(-amount),
      result = Facility.result.boolean,
    })
  )
end

function Counter:take(amount)
  return perform(self:take_op(amount))
end

local function predicate_op(self, predicate, threshold, demand)
  integer(threshold, 'counter threshold', 3)
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self._location,
      demand = demand,
      query = { kind = 'predicate', predicate = predicate, threshold = threshold },
      result = Facility.result.value,
    })
  )
end

function Counter:at_least_op(value)
  return predicate_op(self, 'ge', value, 'up')
end

function Counter:at_least(value)
  return perform(self:at_least_op(value))
end

function Counter:at_most_op(value)
  return predicate_op(self, 'le', value, 'down')
end

function Counter:at_most(value)
  return perform(self:at_most_op(value))
end

function Counter:equal_op(value)
  return predicate_op(self, 'eq', value)
end

function Counter:equal(value)
  return perform(self:equal_op(value))
end

function Counter:zero_op()
  return self:equal_op(0)
end

function Counter:zero()
  return perform(self:zero_op())
end

Counter.Kind = Kind

return Counter
