local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Counter = {}
Counter.__index = Counter
local Kind = Facility.kind('counter')

local function integer(value, label, level)
  if type(value) ~= 'number' or value % 1 ~= 0 then
    error(label .. ' must be an integer', level or 3)
  end
  return value
end

local function at_least(current, threshold)
  if current < threshold then return nil end
  return Facility.outcome(nil, current)
end

local function at_most(current, threshold)
  if current > threshold then return nil end
  return Facility.outcome(nil, current)
end

local function equal(current, threshold)
  if current ~= threshold then return nil end
  return Facility.outcome(nil, current)
end

local function create(initial, minimum, maximum)
  integer(initial, 'counter initial value', 3)
  integer(minimum, 'counter minimum', 3)
  if maximum ~= nil then integer(maximum, 'counter maximum', 3) end
  if initial < minimum or maximum and initial > maximum then
    error('counter initial value is outside its range', 3)
  end
  if maximum and minimum > maximum then error('counter minimum must not exceed maximum', 3) end

  local counter = Facility.identity(setmetatable({ _min = minimum, _max = maximum }, Counter), Kind)
  counter._location = Facility.location(counter, { algebra = 'add', domain = 'counter', value = initial })
  counter._read_op = Facility.op(Facility.read(counter._location, Facility.result.value, counter))
  return counter
end

function Counter.new(initial) return create(initial or 0, 0, nil) end

function Counter.bounded(capacity)
  integer(capacity, 'counter capacity', 2)
  if capacity < 0 then error('counter capacity must be non-negative', 2) end
  return create(capacity, 0, capacity)
end

function Counter.range(initial, minimum, maximum) return create(initial, minimum, maximum) end
function Counter:read_op() return self._read_op end

function Counter:adjust_op(amount)
  integer(amount, 'counter adjustment', 2)
  if amount == 0 then return Op.always(true) end
  local spec = self._adjust_spec
  if not spec then
    spec = Facility.add(self._location, Facility.result.boolean, self)
    self._adjust_spec = spec
  end
  return Facility.bind(spec, amount)
end

function Counter:add_op(amount)
  integer(amount, 'counter addition', 2)
  if amount < 0 then error('counter addition must be non-negative', 2) end
  return self:adjust_op(amount)
end

function Counter:bump_op()
  local op = self._bump_op
  if not op then
    op = Facility.bind(Facility.add(self._location, Facility.result.value, self), 1)
    self._bump_op = op
  end
  return op
end

function Counter:give_op(amount) return self:add_op(amount or 1) end

function Counter:take_op(amount)
  amount = amount or 1
  integer(amount, 'counter take', 2)
  if amount < 0 then error('counter take must be non-negative', 2) end
  if amount == 0 then return Op.always(true) end
  local spec = self._take_spec
  if not spec then
    spec = Facility.rule.change({
      location = self._location, resource = self, demand = 'up',
      visibility = 'together', supply = 'down',
      step = function(current, n)
        if current < self._min + n then return nil end
        return Facility.outcome(Facility.patch.add(-n), true)
      end,
    })
    self._take_spec = spec
  end
  return Facility.bind(spec, amount)
end

local function predicate_op(self, field, demand, step, threshold)
  integer(threshold, 'counter threshold', 3)
  local spec = self[field]
  if not spec then
    spec = Facility.rule.inspect({
      location = self._location, resource = self, demand = demand,
      visibility = 'together', step = step,
    })
    self[field] = spec
  end
  return Facility.bind(spec, threshold)
end

function Counter:at_least_op(value) return predicate_op(self, '_at_least_spec', 'up', at_least, value) end
function Counter:at_most_op(value) return predicate_op(self, '_at_most_spec', 'down', at_most, value) end
function Counter:equal_op(value) return predicate_op(self, '_equal_spec', nil, equal, value) end
function Counter:zero_op() return self:equal_op(0) end

Counter.Kind = Kind
Direct.install(Counter, { 'read', 'adjust', 'add', 'bump', 'give', 'take', 'at_least', 'at_most', 'equal', 'zero' })

return Counter
