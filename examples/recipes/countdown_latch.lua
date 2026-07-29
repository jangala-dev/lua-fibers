-- Transactional countdown latch built on typed Machine transitions.
--
-- A CountdownLatch tracks a count and a generation.  wait_op() succeeds only when
-- the projected count for the committed world is zero.  Under `together`, a sibling
-- done_op() can therefore satisfy a wait; under `each`, sibling positive supply
-- is hidden from the zero predicate.

local StateMachine = require('fibers.resource.machine')
local Ready, Wait = StateMachine.Ready, StateMachine.Wait

local CountdownLatch = {}
CountdownLatch.__index = CountdownLatch

local next_id = 0

local function integer(n, name, level)
  if type(n) ~= 'number' or n ~= math.floor(n) then
    error(name .. ' must be an integer', level or 3)
  end
  return n
end

local function copy_state(st)
  st = st or {}
  return {
    count = st.count or 0,
    generation = st.generation or 0,
  }
end

local Add = StateMachine.select(
  'countdown_latch.add',
  function(st, payload)
    st = copy_state(st)
    local n = payload.n
    local new_count = st.count + n
    if new_count < 0 then
      return Wait
    end
    local generation = st.generation
    if st.count == 0 and new_count > 0 then
      generation = generation + 1
    end
    return Ready.write({ count = new_count, generation = generation }, true, new_count, generation)
  end,
  0,
  function(payload)
    integer(payload.n, 'countdown_latch add amount', 3)
  end
)

local WaitForZero = StateMachine.select('countdown_latch.wait', function(st)
  st = copy_state(st)
  if st.count == 0 then
    return Ready.write(st, true, st.generation)
  end
  return Wait
end, 100)

function CountdownLatch.new(opts, name)
  opts = opts or {}
  if type(opts) == 'string' then
    opts = { name = opts }
  end
  next_id = next_id + 1
  local id = 'countdown_latch-' .. tostring(next_id)
  local wname = opts.name or name or id
  local count = opts.count or 0
  local generation = opts.generation or 0
  integer(count, 'countdown_latch initial count', 2)
  integer(generation, 'countdown_latch initial generation', 2)
  if count < 0 then
    error('countdown_latch initial count must be non-negative', 2)
  end
  if generation < 0 then
    error('countdown_latch initial generation must be non-negative', 2)
  end
  return setmetatable({
    name = wname,
    state = opts.state or StateMachine.new({ count = count, generation = generation }, wname .. ':state'),
  }, CountdownLatch)
end

function CountdownLatch:add_op(n)
  n = n or 1
  integer(n, 'countdown_latch add amount', 2)
  if n == 0 then
    return self:state_op():map(function(st)
      return true, st.count, st.generation
    end)
  end
  return self.state:transition_op(Add, { n = n })
end

function CountdownLatch:done_op()
  return self:add_op(-1)
end

function CountdownLatch:wait_op()
  return self.state:transition_op(WaitForZero)
end

function CountdownLatch:state_op()
  return self.state:read_op():map(function(st)
    return copy_state(st)
  end)
end

return CountdownLatch
