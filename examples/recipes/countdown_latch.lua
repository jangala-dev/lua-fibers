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

local Add = StateMachine.select('countdown_latch.add', function(st, payload)
    st = copy_state(st)
    local n = payload.n
    local new_count = st.count + n
    if new_count < 0 then
      return Wait
    end
    local generation = st.generation
    if n == 0 then return Ready.same(true, st.count, generation) end
    if st.count == 0 and new_count > 0 then
      generation = generation + 1
    end
    return Ready.write({ count = new_count, generation = generation }, true, new_count, generation)
end, 0, function(payload)
  integer(payload.n, 'countdown_latch add amount', 3)
end)

local WaitForZero = StateMachine.select('countdown_latch.wait', function(st)
    st = copy_state(st)
    if st.count == 0 then
      return Ready.write(st, true, st.generation)
    end
    return Wait
end, 100)

function CountdownLatch.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'countdown_latch-' .. tostring(next_id)
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
    _fibers_id = id,
    state = opts.state or StateMachine.new({ count = count, generation = generation }),
  }, CountdownLatch)
end

function CountdownLatch:label(...)
  if select('#', ...) == 0 then return self._label end
  local value = select(1, ...)
  if value ~= nil and (type(value) ~= 'string' or value == '') then
    error('CountdownLatch:label expects a non-empty string or nil', 2)
  end
  self._label = value
  self.state:label(value and value .. ':state' or nil)
  return self
end

function CountdownLatch:add_op(n)
  n = n or 1
  integer(n, 'countdown_latch add amount', 2)
  return self.state:transition_op(Add, { n = n })
end

function CountdownLatch:done_op()
  return self:add_op(-1)
end

function CountdownLatch:wait_op()
  return self.state:transition_op(WaitForZero)
end

return CountdownLatch
