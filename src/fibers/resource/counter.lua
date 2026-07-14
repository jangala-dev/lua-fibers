local Op = require('fibers.op')
local Substrate = require('fibers.internal.kernel.store')

local Counter = {}
Counter.__index = Counter
local Kind = { name = 'counter' }
local next_id = 0

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
    min = opts.min
    max = opts.max
    name = opts.name or name
  else
    initial = opts
  end
  if initial == nil then
    initial = 0
  end
  if min == nil then
    min = 0
  end
  next_id = next_id + 1
  local counter = setmetatable({
    value = initial,
    min = min,
    max = max,
    version = 0,
    name = name or ('counter-' .. tostring(next_id)),
    _fibers_id = 'counter-' .. tostring(next_id),
    _fibers_kind = Kind,
  }, Counter)
  counter._location = Substrate.new_location({
    name = counter.name .. ':stock',
    merge = 'add',
    domain = 'counter',
    value = initial,
    owner = counter,
    apply = function(v, loc)
      counter.value = v
      counter.version = loc.version
    end,
  })
  counter._read_op = Op._compact_resource(counter, Kind, 'read', {
    location = counter._location,
    result_kind = 'identity',
  })
  counter._state_op = Op._compact_resource(counter, Kind, 'read', {
    location = counter._location,
    result_kind = 'counter_state',
    owner = counter,
  })
  return counter
end

function Counter:adjust_op(n)
  if n == nil then
    error('counter adjust requires an amount', 2)
  end
  return Op._compact_resource(self, Kind, 'patch', {
    location = self._location,
    patch = { kind = 'add', delta = n },
    result_kind = 'constant',
    result_value = true,
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
  local loc = self._location
  return Op._compact_resource(self, Kind, 'claim', {
    location = loc,
    group = self,
    orientation = 'up',
    predicate = 'ge',
    threshold = (self.min or 0) + n,
    query = { kind = 'predicate', predicate = 'ge', threshold = (self.min or 0) + n },
    transition = { kind = 'static', patch = { kind = 'add', delta = -n } },
    result_kind = 'constant',
    result_value = true,
  })
end
function Counter:read_op()
  return self._read_op
end
function Counter:state_op()
  return self._state_op
end

Counter.Kind = Kind
return Counter
