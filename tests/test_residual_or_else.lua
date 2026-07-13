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

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Rendezvous = require('fibers.atoms.rendezvous')
local Signal = require('fibers.atoms.signal')

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
    got = rt:perform(
      Rendezvous.new('cursor-residual-no-sender'):get_op():or_else(Op.always('fallback'))
    )
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

print('tests/test_residual_or_else.lua: focused residual semantics ok')

print('tests/test_residual_or_else.lua: ok')
