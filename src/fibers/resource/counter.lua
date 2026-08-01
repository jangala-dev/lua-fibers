local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Counter = {}
Counter.__index = function(self, key)
  if key == 'value' then return self._location.value end
  if key == 'version' then return self._location.version end
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
  if maximum ~= nil then integer(maximum, 'counter maximum', 3) end
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
  counter._read_op = Facility.op(Facility.read(counter._location, Facility.result.value, counter))
  counter._changed_spec = Facility.version_wait(counter._location, counter)
  return counter
end

function Counter.new(initial, name)
  return create(initial or 0, 0, nil, name)
end

function Counter.bounded(capacity, name)
  integer(capacity, 'counter capacity', 2)
  if capacity < 0 then error('counter capacity must be non-negative', 2) end
  return create(capacity, 0, capacity, name)
end

function Counter.range(initial, minimum, maximum, name)
  return create(initial, minimum, maximum, name)
end

function Counter:read_op()
  return self._read_op
end


function Counter:changed_op(version)
  return Facility.bind(self._changed_spec, version)
end


function Counter:adjust_op(amount)
  integer(amount, 'counter adjustment', 2)
  if amount == 0 then return Op.always(self.value) end
  return Facility.op(Facility.write(self._location, Facility.patch.add(amount), Facility.result.boolean, self))
end


function Counter:add_op(amount)
  integer(amount, 'counter addition', 2)
  if amount < 0 then error('counter addition must be non-negative', 2) end
  return self:adjust_op(amount)
end


function Counter:bump_op()
  return Facility.op(Facility.write(self._location, Facility.patch.add(1), Facility.result.value, self))
end


function Counter:give_op(amount)
  return self:add_op(amount or 1)
end


function Counter:take_op(amount)
  amount = amount or 1
  integer(amount, 'counter take', 2)
  if amount < 0 then error('counter take must be non-negative', 2) end
  if amount == 0 then return Op.always(self.value) end
  return Facility.op(Facility.rule.change({
    location = self._location,
    resource = self,
    demand = 'up',
    visibility = 'together',
    supply = 'down',
    step = function(current)
      if current < self.min + amount then return nil end
      return Facility.outcome(Facility.patch.add(-amount), true)
    end,
  }))
end


local function predicate_op(self, predicate, threshold, demand)
  integer(threshold, 'counter threshold', 3)
  return Facility.op(Facility.rule.inspect({
    location = self._location,
    resource = self,
    demand = demand,
    visibility = 'together',
    step = function(current)
      local ready = predicate == 'ge' and current >= threshold
        or predicate == 'le' and current <= threshold
        or predicate == 'eq' and current == threshold
      if not ready then return nil end
      return Facility.outcome(nil, current)
    end,
  }))
end

function Counter:at_least_op(value)
  return predicate_op(self, 'ge', value, 'up')
end


function Counter:at_most_op(value)
  return predicate_op(self, 'le', value, 'down')
end


function Counter:equal_op(value)
  return predicate_op(self, 'eq', value)
end


function Counter:zero_op()
  return self:equal_op(0)
end


Counter.Kind = Kind

Direct.install(Counter, { 'read', 'changed', 'adjust', 'add', 'bump', 'give', 'take', 'at_least', 'at_most', 'equal', 'zero' })

return Counter
