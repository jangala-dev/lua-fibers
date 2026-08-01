-- Law-level checks for the exhaustive absence judgement which authorises
-- proof-directed or_else fallback in the evaluator.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Signal = require('fibers.resource.signal')

local function fail(msg)
  error(msg, 2)
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
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

local ABSENT = {}
local function absent(op)
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(op:or_else(Op.always(ABSENT)))
  end, 'absence-probe')
  local status = rt:run()
  assert_status(status, 'found', 'absence probe should commit either primary or fallback')
  return got == ABSENT
end

-- choice is absent exactly when all alternatives are absent.
do
  assert_truthy(absent(Op.choice(Op.never(), Op.never())), 'all-absent choice should be absent')
  assert_falsy(
    absent(Op.choice(Op.never(), Op.always('live'))),
    'one live choice branch should defeat absence'
  )
  assert_falsy(absent(Op.choice(Op.always('live'), Op.never())), 'branch order does not affect absence')
end

-- Nested or_else is absent only when both the preferred option and fallback
-- have no current world.
do
  assert_truthy(absent(Op.never():or_else(Op.never())), 'or_else with both sides absent should be absent')
  assert_falsy(
    absent(Op.never():or_else(Op.always('fallback'))),
    'available fallback makes the whole or_else available'
  )
  assert_falsy(
    absent(Op.always('primary'):or_else(Op.never())),
    'available primary makes the whole or_else available'
  )
end

-- map and wrap preserve absence of the inner option; a wrap from an absent
-- primary is not run when the fallback commits.
do
  local wrapped = false
  assert_truthy(
    absent(Op.never():map(function()
      return 'unreachable'
    end)),
    'map preserves inner absence'
  )
  assert_falsy(
    absent(Op.always('x'):map(function(v)
      return v
    end)),
    'map preserves inner availability'
  )
  assert_truthy(
    absent(Op.never():wrap(function(v)
      wrapped = true
      return v
    end)),
    'wrap preserves inner absence'
  )

  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(Op.never()
      :wrap(function(v)
        wrapped = true
        return v
      end)
      :or_else(Op.always('fallback')))
  end, 'wrap-absence-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(wrapped, false, 'wrap on absent primary must not run')
end

-- An and_then whose prefix is absent is absent without entering its right-hand operation.
do
  local called = false
  assert_truthy(
    absent(Op.never():and_then(Op.guard(function()
      called = true
      return Op.always('bad')
    end))),
    'and_then with absent prefix should be absent'
  )
  assert_eq(called, false, 'and_then right-hand guard must not run when the prefix is absent')
end

-- together permits internal rendezvous, while each does not.
do
  local ch = Rendezvous.new('absence-law-rendezvous')
  assert_falsy(
    absent(Op.together({ ch:get_op(), ch:put_op('payload') })),
    'an internal rendezvous in together is a current world'
  )
  assert_truthy(
    absent(Op.each({ ch:get_op(), ch:put_op('payload') })),
    'each cannot close its own rendezvous'
  )
  assert_truthy(absent(Op.together({ ch:get_op() })), 'an unpaired rendezvous in together is absent')
end

-- Resources do not author Retry proofs. An external wait contributes a
-- kernel-owned wake interest, and or_else may consume its exhaustive current
-- absence without retaining the discarded primary interest afterwards.
do
  local signal = Signal.new('retry-law-signal')
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(signal:wait_op():or_else(Op.always('fallback')))
  end, 'signal-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')

  local pending = Runtime.new()
  pending:spawn_raw(function()
    pending:perform(signal:wait_op())
  end, 'signal-wait')
  local st = pending:run()
  assert_status(st, 'pending')
  assert_truthy(
    st.interests and #st.interests == 1,
    'unhandled external absence should retain one wake interest'
  )
end

-- Driver turns retain scheduler order, but positive-before-fallback is a
-- dependency-component rule rather than a runtime-wide priority rule.
do
  local got_a, got_b
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got_a = rt:perform(Rendezvous.new('absence-law-no-partner'):get_op():or_else(Op.always('fallback')))
  end, 'fallback-root')
  rt:spawn_raw(function()
    got_b = rt:perform(Op.always('progress'))
  end, 'progress-root')
  local first = rt:step()
  assert_truthy(
    first.tag == 'pending' or first.tag == 'quiescent',
    'first step should expose the fallback root without committing it'
  )
  assert_status(rt:step(), 'found', 'the next independent component follows scheduler order')
  assert_eq(got_b, 'progress')
  assert_eq(got_a, nil)
  assert_status(rt:step(), 'found')
  assert_eq(got_a, 'fallback')
end

-- A perpetually ready independent component must not starve a certified local
-- fallback. Before component-scoped arbitration this fallback committed only
-- after the unrelated producer had drained its complete ready loop.
do
  local unrelated_commits = 0
  local fallback_after
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.never():or_else(Op.always('fallback')))
    fallback_after = unrelated_commits
  end, 'independent-fallback')
  rt:spawn_raw(function()
    for _ = 1, 1000 do
      rt:perform(Op.always(true))
      unrelated_commits = unrelated_commits + 1
    end
  end, 'independent-positive-loop')
  assert_status(rt:run(), 'found')
  assert_eq(fallback_after, 0, 'independent positive work must not delay local fallback')
end

print('tests/test_retry_laws.lua: ok')
