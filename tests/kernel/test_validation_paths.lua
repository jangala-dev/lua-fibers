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
local Cell = require('fibers.resource.cell')

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
  local receiver_request = rt.engine.pending[#rt.engine.pending]

  local fallback_plan = assert(rt.engine:find_candidate(receiver_request))
  assert_eq(fallback_plan:is_fallback(), true, 'initial plan should be fallback')

  local sender = rt:spawn_raw(function()
    sender_result = rt:perform(ch:put_op('primary'))
  end, 'sender')
  rt:_resume_fiber(sender)

  local committed = fallback_plan:settle(rt.engine)
  assert_eq(committed, false, 'stale negative plan must not commit')

  local refreshed = assert(rt.engine:find_candidate(receiver_request))
  assert_eq(refreshed:is_fallback(), false, 'refreshed plan should use primary')
  assert(refreshed:settle(rt.engine))
  assert_eq(receiver_result, 'primary')
  assert_eq(sender_result, true)
end

-- Two candidates are deliberately built from the same cell version.  The second
-- must fail validation, be rebuilt against the new value, and retain primary
-- preference rather than selecting the fallback.
do
  local rt = Runtime.new()
  local cell = Cell.new(0, 'stale-primary')
  local first_result, second_result
  local guard_calls = 0

  local function increment_result(label)
    return cell:read_op():and_then(Op.guard(function(old)
      return cell:write_op(old + 1):and_then(Op.always(label, old + 1))
    end))
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
  local first_request, second_request = rt.engine.pending[1], rt.engine.pending[2]
  local first_plan = assert(rt.engine:find_candidate(first_request))
  local second_plan = assert(rt.engine:find_candidate(second_request))
  assert_eq(guard_calls, 1, 'guard constructed once while planning')

  assert(first_plan:settle(rt.engine))
  assert_eq(second_plan:settle(rt.engine), false, 'second snapshot plan should be stale')

  local refreshed = assert(rt.engine:find_candidate(second_request))
  assert_eq(refreshed:is_fallback(), false, 'stale primary refresh must remain primary')
  assert(refreshed:settle(rt.engine))

  assert_eq(first_result, 1)
  assert_eq(second_result, 'primary:2')
  assert_eq(cell.value, 2)
  assert_eq(guard_calls, 1, 'guard memo survives stale refresh')
end

print('tests/test_validation_paths.lua: ok')
