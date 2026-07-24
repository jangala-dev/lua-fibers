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
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

-- A negative fallback plan must be invalidated when the pending-participant
-- frontier changes, then re-searched so that the newly available primary wins.
do
  local rt = Runtime.new()
  local ch = Rendezvous.new('negative-frontier')
  local receiver_result, sender_result

  local receiver = rt:spawn_raw(function()
    receiver_result = rt:perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'receiver')
  rt:_resume_fiber(receiver)
  local receiver_id = rt.pending[#rt.pending].id

  local fallback_plan = assert(rt:_find_candidate(receiver_id))
  assert_eq(fallback_plan.absence_gate ~= nil, true, 'initial plan should be fallback')

  local sender = rt:spawn_raw(function()
    sender_result = rt:perform(ch:put_op('primary'))
  end, 'sender')
  rt:_resume_fiber(sender)

  local committed = rt:_commit_hit(fallback_plan)
  assert_eq(committed, false, 'stale negative plan must not commit')
  assert_eq(rt.stats.validation_failures, 1, 'negative-frontier validation failure recorded')

  local refreshed = assert(rt:_find_candidate(receiver_id))
  assert_eq(refreshed.absence_gate ~= nil, false, 'refreshed plan should use primary')
  assert(rt:_commit_hit(refreshed))
  assert_eq(receiver_result, 'primary')
  assert_eq(sender_result, true)
end

-- Two plans are deliberately built from the same scalar version.  The second
-- must fail validation, be rebuilt against the new value, and retain primary
-- preference rather than selecting the fallback.
do
  local rt = Runtime.new()
  local scalar = Scalar.new(0, 'stale-primary')
  local first_result, second_result
  local guard_calls = 0

  local function increment_result(label)
    return scalar:read_op():and_then(function(old)
      return scalar:write_op(old + 1):and_then(function()
        return Op.always(label, old + 1)
      end)
    end)
  end

  local first = rt:spawn_raw(function()
    local _, value = rt:perform(increment_result('first'))
    first_result = value
  end, 'first')
  local second = rt:spawn_raw(function()
    local label, value = rt:perform(Op.guard(function()
      guard_calls = guard_calls + 1
      return increment_result('primary')
    end):or_else(Op.always('fallback', -1)))
    second_result = label .. ':' .. tostring(value)
  end, 'second')

  rt:_resume_fiber(first)
  rt:_resume_fiber(second)
  local first_id, second_id = rt.pending[1].id, rt.pending[2].id
  local first_plan = assert(rt:_find_candidate(first_id))
  local second_plan = assert(rt:_find_candidate(second_id))
  assert_eq(guard_calls, 1, 'guard constructed once while planning')

  assert(rt:_commit_hit(first_plan))
  assert_eq(rt:_commit_hit(second_plan), false, 'second snapshot plan should be stale')

  local refreshed = assert(rt:_find_candidate(second_id))
  assert_eq(refreshed.absence_gate ~= nil, false, 'stale primary refresh must remain primary')
  assert(rt:_commit_hit(refreshed))

  assert_eq(first_result, 1)
  assert_eq(second_result, 'primary:2')
  assert_eq(scalar.value, 2)
  assert_eq(guard_calls, 1, 'guard memo survives stale refresh')
end

print('tests/test_validation_paths.lua: ok')
