-- Law-level checks for the algebraic absence judgement used to justify
-- or_else fallbacks.  These are deliberately smaller than the adversarial
-- Region/Task/Flow scenarios: they assert the option-algebra rules directly.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Debug = require('fibers.kernel.transaction_debug')
local Channel = require('fibers.base.channel')
local Result = require('fibers.kernel.resources.result')

local function fail(msg) error(msg, 2) end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

local function absent(op)
  local status = Debug.perform_sync(Runtime.new(), op)
  return status.tag == 'absent'
end

-- choice is absent exactly when all alternatives are absent.
do
  assert_truthy(absent(Op.choice(Op.never(), Op.never())), 'all-absent choice should be absent')
  assert_falsy(absent(Op.choice(Op.never(), Op.always('live'))), 'one live choice branch should defeat absence')
  assert_falsy(absent(Op.choice(Op.always('live'), Op.never())), 'absence is not left-biased')
end

-- nested or_else is absent only when both the preferred option and the
-- fallback have no current world.
do
  assert_truthy(absent(Op.never():or_else(Op.never())), 'or_else with both sides absent should be absent')
  assert_falsy(absent(Op.never():or_else(Op.always('fallback'))), 'available fallback makes the whole or_else available')
  assert_falsy(absent(Op.always('primary'):or_else(Op.never())), 'available primary makes the whole or_else available')
end

-- map and wrap preserve absence of the inner option; a wrap from an absent
-- primary is not run when the fallback commits.
do
  local wrapped = false
  assert_truthy(absent(Op.never():map(function() return 'unreachable' end)), 'map preserves inner absence')
  assert_falsy(absent(Op.always('x'):map(function(v) return v end)), 'map preserves inner availability')
  assert_truthy(absent(Op.never():wrap(function(v) wrapped = true; return v end)), 'wrap preserves inner absence')

  local got
  local st = Runtime.new()
  st:spawn_raw(function()
    got = st:perform(Op.never():wrap(function(v) wrapped = true; return v end):or_else(Op.always('fallback')))
  end, 'wrap-absence-fallback')
  assert_status(st:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(wrapped, false, 'wrap on absent primary must not run')
end

-- A bind whose prefix is absent is absent without running the continuation.
do
  local called = false
  assert_truthy(absent(Op.never():and_then(function() called = true; return Op.always('bad') end)), 'bind with absent prefix should be absent')
  assert_eq(called, false, 'bind continuation must not run when the prefix is absent')
end

-- tensor permits internal rendezvous, while all does not.
do
  local ch = Channel.new('absence-law-channel')
  assert_falsy(absent(Op.tensor({ ch:get_op(), ch:put_op('payload') })), 'tensor-internal rendezvous is a current world')
  assert_truthy(absent(Op.all({ ch:get_op(), ch:put_op('payload') })), 'all cannot close its own rendezvous')
  assert_truthy(absent(Op.tensor({ ch:get_op() })), 'unpaired tensor rendezvous is absent')
end

-- Absence is explicit by resource kind; an unknown blocking resource is not
-- given a plausible catch-all absence certificate by default.
do
  local fake = { name = 'fake-resource' }
  local FakeKind = { name = 'fake', eval = function() return Result.blocked() end }
  assert_falsy(absent(Op._resource(fake, FakeKind, { op = 'wait' })), 'unknown resource absence is uncertified')
end

-- Runtime priority law: any non-absence world still beats an absence-certified
-- fallback world in another root.
do
  local got_a, got_b
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got_a = rt:perform(Channel.new('absence-law-no-partner'):get_op():or_else(Op.always('fallback')))
  end, 'fallback-root')
  rt:spawn_raw(function()
    got_b = rt:perform(Op.always('progress'))
  end, 'progress-root')
  assert_status(rt:step(), 'pending', 'first step starts fallback root')
  assert_status(rt:step(), 'pending', 'second step starts progress root')
  assert_status(rt:step(), 'found', 'non-absence progress commits before fallback')
  assert_eq(got_b, 'progress', 'ordinary progress should commit first')
  assert_eq(got_a, nil, 'absence fallback remains pending for a later turn')
  assert_status(rt:step(), 'found', 'fallback may commit once no ordinary progress remains')
  assert_eq(got_a, 'fallback')
end

print('tests/test_absence_laws.lua: ok')
