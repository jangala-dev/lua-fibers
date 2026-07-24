-- Focused residual or_else tests.
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local machine = Runtime.new().machine_name
local Rendezvous = require('fibers.resource.rendezvous')
local Signal = require('fibers.resource.signal')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_falsy(v, msg)
  if v then
    fail((msg or 'expected falsy') .. ': got ' .. tostring(v))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end
local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end
local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local values = { n = 0 }
  rt:spawn_raw(function()
    values = pack_(rt:perform(op))
  end, 'one')
  local st = rt:run()
  return st, values, rt
end

-- Primary success must not construct fallback.
do
  local constructed = 0
  local st, values = one_perform(Op.always('primary'):or_else(Op.guard(function()
    constructed = constructed + 1
    return Op.always('fallback')
  end)))
  assert_status(st, 'found')
  assert_eq(values[1], 'primary')
  assert_eq(constructed, 0, 'fallback guard was not entered')
end

-- Local primary absence enters fallback.
do
  local constructed = 0
  local st, values = one_perform(Op.never():or_else(Op.guard(function()
    constructed = constructed + 1
    return Op.always('fallback')
  end)))
  assert_status(st, 'found')
  assert_eq(values[1], 'fallback')
  assert_eq(constructed, 1)
end

-- Promoted or_else occurrences retain one watched preferred state. Individual
-- branch failures report evidence before final primary closure activates the
-- fallback.
if machine == 'ledger' then
  local rt = Runtime.new({ instrumentation = true })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(Op.never(), Op.never()):or_else(Op.always('fallback')))
  end, 'watched-preferred-state')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  local counters = rt:instrumentation_snapshot().counters
  assert_truthy((counters.preferred_states_opened or 0) >= 1, 'preferred state opened')
  assert_truthy(
    (counters.preferred_states_closed or 0) >= 1
      and counters.preferred_states_closed <= counters.preferred_states_opened,
    'preferred states close at most once per promoted occurrence'
  )
  assert_truthy(
    (counters.preferred_state_evidence or 0) >= 3,
    'choice failures and final closure reported into preferred state'
  )
  assert_eq(
    counters.fallback_dependency_transitions or 0,
    counters.preferred_states_closed or 0,
    'each closed preferred occurrence performs one dependency transition to fallback'
  )
end

-- Future waitability of primary does not suppress fallback, and primary wait is discarded.
do
  local ev = Signal.new('residual-unready')
  local st, values = one_perform(ev:wait_op():or_else(Op.always('fallback')))
  assert_status(st, 'found')
  assert_eq(values[1], 'fallback')
end

-- If fallback also has no current world, primary waits do not survive residual fallback.
do
  local ev = Signal.new('residual-unready-never')
  local st = one_perform(ev:wait_op():or_else(Op.never()), { quiet_deadlock = true })
  assert_status(st, 'quiescent', 'left wait was discarded when fallback was absent')
end

-- Global rendezvous primary still beats fallback.
do
  local ch = Rendezvous.new('residual-primary')
  local rt = Runtime.new()
  local got, sent
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function()
    sent = rt:perform(ch:put_op('payload'))
  end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
  assert_eq(sent, true)
end

-- Partner backtracking can still make primary available.
do
  local wanted = Rendezvous.new('residual-wanted')
  local dead = Rendezvous.new('residual-dead')
  local rt = Runtime.new()
  local receiver, partner
  rt:spawn_raw(function()
    receiver = rt:perform(wanted
      :get_op()
      :map(function(v)
        return 'primary:' .. v
      end)
      :or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function()
    partner = rt:perform(Op.choice(dead:put_op('dead'), wanted:put_op('ok')))
  end, 'partner')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:ok')
  assert_eq(partner, true)
end

-- Bounded cursor also opens residual fallback over repeated steps.
do
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(Rendezvous.new('cursor-residual-no-sender'):get_op():or_else(Op.always('fallback')))
  end, 'cursor-residual')
  local st
  for _ = 1, 80 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then
      break
    end
  end
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
end

-- Bounded cursor must not commit fallback before an unstarted sender can make
-- the primary globally available.
do
  local ch = Rendezvous.new('cursor-residual-with-sender')
  local rt = Runtime.new()
  local got, sent
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function()
    sent = rt:perform(ch:put_op('payload'))
  end, 'sender')
  local st
  for _ = 1, 120 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then
      break
    end
  end
  assert_status(st, 'found')
  assert_eq(got, 'payload')
  assert_eq(sent, true)
end

-- Batched fallbacks should prove preferred absence in phase-local components,
-- then perform one normal fallback search.  Re-running the complete negative
-- transaction once per fallback producer gives quadratic growth.
-- Nested fallbacks are occurrence-local phases, not a Cartesian choice of
-- fallback depths across product lanes. Once a preferred occurrence is closed,
-- the fallback is installed in the parent proof node before another sibling
-- fallback is opened.
if machine == 'ledger' then
  local count, levels = 12, 3
  local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
  local ready, values = {}, nil
  runtime:spawn_raw(function()
    local lanes = {}
    for i = 1, count do
      local operation
      for level = 1, levels do
        local absent = Rendezvous.new('nested-fallback-absent-' .. tostring(i) .. '-' .. tostring(level))
        operation = operation and operation:or_else(absent:get_op()) or absent:get_op()
      end
      ready[i] = Rendezvous.new('nested-fallback-ready-' .. tostring(i))
      lanes[i] = operation:or_else(ready[i]:get_op())
    end
    values = runtime:perform(Op.all(lanes))
  end, 'nested-fallback-consumer')
  for i = 1, count do
    local value = i
    runtime:spawn_raw(function()
      runtime:perform(ready[value]:put_op(value))
    end, 'nested-fallback-producer-' .. tostring(i))
  end
  assert_eq(runtime:run().tag, 'found')
  assert_eq(runtime:run().tag, 'idle')
  assert_truthy(values ~= nil, 'nested fallback did not complete')
  local counters = runtime:instrumentation_snapshot().counters
  assert_truthy(
    (counters.search_calls or math.huge) < 300,
    'nested fallback regressed to fallback-depth enumeration'
  )
end

-- Interacting products must preserve sibling supply while allowing an exact
-- preferred exchange with no admissible sibling or pending supplier to close
-- locally.  Each closure is trailed independently so sibling fallback phases do
-- not form a Cartesian search.
if machine == 'ledger' then
  local count, levels = 16, 2
  local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
  local values
  runtime:spawn_raw(function()
    local lanes = {}
    for i = 1, count do
      local operation
      for level = 1, levels do
        local absent = Rendezvous.new('tensor-fallback-absent-' .. tostring(i) .. '-' .. tostring(level))
        operation = operation and operation:or_else(absent:get_op()) or absent:get_op()
      end
      local ready = Rendezvous.new('tensor-fallback-ready-' .. tostring(i))
      lanes[#lanes + 1] = operation:or_else(ready:get_op())
      lanes[#lanes + 1] = ready:put_op(i)
    end
    values = runtime:perform(Op.tensor(lanes))
  end, 'tensor-fallback-root')
  assert_eq(runtime:run().tag, 'found')
  assert_eq(runtime:run().tag, 'idle')
  assert_truthy(values ~= nil, 'interacting tensor fallback did not complete')
  local counters = runtime:instrumentation_snapshot().counters
  assert_truthy(
    (counters.search_calls or math.huge) < 250,
    'interacting tensor fallback regressed to sibling-phase enumeration'
  )
  assert_truthy(
    (counters.product_support_closures or 0) >= count * levels,
    'product support closures were not reported'
  )
end

if machine == 'ledger' then
  local count = 32
  local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
  local ready, values = {}, nil
  runtime:spawn_raw(function()
    local lanes = {}
    for i = 1, count do
      local absent = Rendezvous.new('batched-fallback-absent-' .. tostring(i))
      ready[i] = Rendezvous.new('batched-fallback-ready-' .. tostring(i))
      lanes[i] = absent:get_op():or_else(ready[i]:get_op())
    end
    values = runtime:perform(Op.all(lanes))
  end, 'batched-fallback-consumer')
  for i = 1, count do
    local value = i
    runtime:spawn_raw(function()
      runtime:perform(ready[value]:put_op(value))
    end, 'batched-fallback-producer-' .. tostring(i))
  end
  assert_eq(runtime:run().tag, 'found')
  assert_eq(runtime:run().tag, 'idle')
  assert_truthy(values ~= nil, 'batched fallback did not complete')
  local counters = runtime:instrumentation_snapshot().counters
  assert_truthy((counters.search_calls or math.huge) < 300, 'batched fallback regressed to repeated search')
end

print('tests/test_residual_or_else.lua: focused residual semantics ok')

print('tests/test_residual_or_else.lua: ok')
