package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.resources.channel')
local Event = require('fibers.resources.event')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end
local pack_ = table.pack or function(...) return { n = select('#', ...), ... } end
local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local values = { n = 0 }
  rt:spawn(function() values = pack_(rt:perform(op)) end, 'one')
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

-- Protected absent primary is discarded, not nacked.
do
  local ref
  local st, values = one_perform(Op.with_nack(function(nack)
    ref = nack.obligation
    return Op.never()
  end):or_else(Op.always('fallback')))
  assert_status(st, 'found')
  assert_eq(values[1], 'fallback')
  assert_truthy(ref)
  local st2 = one_perform(Op._nack(ref), { quiet_deadlock = true })
  assert_falsy(st2 and st2.tag == 'found', 'absent primary did not produce a nack')
end

-- Future waitability of primary does not suppress fallback, and primary wait is discarded.
do
  local ev = Event.new('residual-unready')
  local st, values = one_perform(ev:wait_op(Op):or_else(Op.always('fallback')))
  assert_status(st, 'found')
  assert_eq(values[1], 'fallback')
end

-- If fallback also has no current world, primary waits do not survive residual fallback.
do
  local ev = Event.new('residual-unready-never')
  local st = one_perform(ev:wait_op(Op):or_else(Op.never()), { quiet_deadlock = true })
  assert_status(st, 'absent', 'left wait was discarded when fallback was absent')
end

-- Fallback, once entered, is a normal offer and can be nacked by an outer choice.
do
  local ref
  local rt = Runtime.new()
  local got
  rt:spawn(function()
    got = rt:perform(Op.choice(
      Op.always('outer'),
      Op.never():or_else(Op.with_nack(function(nack)
        ref = nack.obligation
        return Op.always('fallback')
      end))
    ))
  end, 'outer-choice')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'outer')
  assert_truthy(ref, 'fallback was entered before losing to outer choice')
  local st2, values2 = one_perform(Op._nack(ref))
  assert_status(st2, 'found')
  assert_eq(values2[1], true)
end

-- Global rendezvous primary still beats fallback.
do
  local ch = Channel.new('residual-primary')
  local rt = Runtime.new()
  local got, sent
  rt:spawn(function() got = rt:perform(ch:get_op(Op):or_else(Op.always('fallback'))) end, 'receiver')
  rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'payload')) end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
  assert_eq(sent, true)
end

-- Partner backtracking can still make primary available.
do
  local wanted = Channel.new('residual-wanted')
  local dead = Channel.new('residual-dead')
  local rt = Runtime.new()
  local receiver, partner
  rt:spawn(function()
    receiver = rt:perform(wanted:get_op(Op):map(function(v) return 'primary:' .. v end):or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn(function()
    partner = rt:perform(Op.choice(dead:put_op(Op, 'dead'), wanted:put_op(Op, 'ok')))
  end, 'partner')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:ok')
  assert_eq(partner, true)
end


-- Bounded cursor also opens residual fallback over repeated steps.
do
  local rt = Runtime.new()
  local got
  rt:spawn(function()
    got = rt:perform(Channel.new('cursor-residual-no-sender'):get_op(Op):or_else(Op.always('fallback')))
  end, 'cursor-residual')
  local st
  for _ = 1, 80 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then break end
  end
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
end

-- Bounded cursor must not commit fallback before an unstarted sender can make
-- the primary globally available.
do
  local ch = Channel.new('cursor-residual-with-sender')
  local rt = Runtime.new()
  local got, sent
  rt:spawn(function() got = rt:perform(ch:get_op(Op):or_else(Op.always('fallback'))) end, 'receiver')
  rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'payload')) end, 'sender')
  local st
  for _ = 1, 120 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then break end
  end
  assert_status(st, 'found')
  assert_eq(got, 'payload')
  assert_eq(sent, true)
end

print('residual or_else semantics: ok')
