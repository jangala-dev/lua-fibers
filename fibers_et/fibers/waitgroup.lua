-- Transactional wait group built on typed Scalar transitions.
--
-- A WaitGroup tracks a count and a generation.  wait_op() succeeds only when
-- the projected count for the committed world is zero.  Under tensor a sibling
-- done_op() can therefore satisfy a wait; under all a sibling positive supply
-- is not hidden from the zero predicate.

local Scalar = require('fibers.atoms.scalar')

local WaitGroup = {}
WaitGroup.__index = WaitGroup

local next_id = 0

local function integer(n, name, level)
  if type(n) ~= 'number' or n ~= math.floor(n) then error(name .. ' must be an integer', level or 3) end
  return n
end

local function copy_state(st)
  st = st or {}
  return {
    count = st.count or 0,
    generation = st.generation or 0,
  }
end

local State = Scalar.kind {
  name = 'waitgroup.state',
  transitions = {
    add = {
      mode = 'select',
      order = 0,
      validate = function(payload) integer(payload.n, 'waitgroup add amount', 3) end,
      step = function(st, payload)
        st = copy_state(st)
        local n = payload.n
        local new_count = st.count + n
        if new_count < 0 then return nil end
        local generation = st.generation
        if st.count == 0 and new_count > 0 then generation = generation + 1 end
        return { count = new_count, generation = generation }, true, new_count, generation
      end,
    },
    wait = {
      mode = 'select',
      order = 100,
      step = function(st)
        st = copy_state(st)
        if st.count == 0 then return st, true, st.generation end
        return nil
      end,
    },
  },
}

function WaitGroup.new(opts, name)
  opts = opts or {}
  if type(opts) == 'string' then opts = { name = opts } end
  next_id = next_id + 1
  local id = 'waitgroup-' .. tostring(next_id)
  local wname = opts.name or name or id
  local count = opts.count or 0
  local generation = opts.generation or 0
  integer(count, 'waitgroup initial count', 2)
  integer(generation, 'waitgroup initial generation', 2)
  if count < 0 then error('waitgroup initial count must be non-negative', 2) end
  if generation < 0 then error('waitgroup initial generation must be non-negative', 2) end
  return setmetatable({
    name = wname,
    state = opts.state or Scalar.new({ count = count, generation = generation }, wname .. ':state'),
  }, WaitGroup)
end

function WaitGroup:add_op(n)
  n = n or 1
  integer(n, 'waitgroup add amount', 2)
  if n == 0 then return self:state_op():map(function(st) return true, st.count, st.generation end) end
  return self.state:transition_op(State:transition('add'), { n = n })
end

function WaitGroup:done_op()
  return self:add_op(-1)
end

function WaitGroup:wait_op()
  return self.state:transition_op(State:transition('wait'))
end

function WaitGroup:state_op()
  return self.state:read_op():map(function(st) return copy_state(st) end)
end

WaitGroup.State = State
return WaitGroup
