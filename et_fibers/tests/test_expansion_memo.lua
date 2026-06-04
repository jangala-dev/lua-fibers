package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local Obligation = require('et.machine.frontier').Obligation

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_status(x, tag, message)
  if not x or x.tag ~= tag then
    error((message or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag) .. ' (' .. tostring(x and x.reason) .. ')', 2)
  end
  return x.value
end

local function reset()
  if Obligation.reset_for_tests then Obligation.reset_for_tests() end
end

local function with_nack_callback_is_memoised_across_refresh()
  reset()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'memo-nack-cell')
  local ch = Channel.new('memo-nack-block')
  local calls = 0
  local got_a, got_b
  local op = Op.with_nack(function(_nack)
    calls = calls + 1
    return cell:get_op(Op):and_then(function(v)
      if v == 0 then return ch:get_op(Op) end
      return Op.always('ok')
    end)
  end)
  rt:spawn(function() got_a = rt:perform(op) end, 'memo-nack-root')
  rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'memo-nack-setter')
  assert_status(rt:run(), 'found')
  assert_eq(got_b, 'set')
  assert_eq(got_a, 'ok')
  assert(rt.stats.refreshes >= 1, 'test should refresh the parked root')
  assert_eq(calls, 1, 'with_nack callback should be forced once for the live attempt occurrence')
end

local function with_nack_callback_runs_again_for_new_perform_attempt()
  reset()
  local rt = Runtime.new()
  local calls = 0
  local op = Op.with_nack(function(_nack)
    calls = calls + 1
    return Op.always('ok')
  end)
  local a, b
  rt:spawn(function()
    a = rt:perform(op)
    b = rt:perform(op)
  end, 'memo-nack-new-attempt')
  assert_status(rt:run(), 'found')
  assert_eq(a, 'ok')
  assert_eq(b, 'ok')
  assert_eq(calls, 2, 'new perform attempt gets fresh with_nack memo cells')
end

local function with_nack_choice_decision_prefixes_are_distinct()
  reset()
  local calls = 0
  local w = Op.with_nack(function(_nack)
    calls = calls + 1
    return Op.always('ok')
  end)
  local view = View.open('memo-choice-view')
  local frontier = assert_status(Frontier.expand_in_search(Op.choice(w, w), { id = 'memo-choice-attempt' }, view), 'found')
  assert(#frontier.frames >= 2, 'both choice branches should be represented')
  assert_eq(calls, 2, 'same syntax under different choice decision prefixes gets distinct memo cells')
end

local function with_nack_product_lanes_are_distinct()
  reset()
  local calls = 0
  local f = function(_nack)
    calls = calls + 1
    return Op.always('ok')
  end
  local view = View.open('memo-lanes-view')
  local frontier = assert_status(Frontier.expand_in_search(Op.tensor({ Op.with_nack(f), Op.with_nack(f) }), { id = 'memo-lanes-attempt' }, view), 'found')
  assert(#frontier.frames >= 1, 'product should expand')
  assert_eq(calls, 2, 'different product lanes get distinct with_nack memo cells')
end

local function nested_with_nack_identity_includes_parent_obligation()
  reset()
  local seen_parent = false
  local op = Op.with_nack(function(n1)
    return Op.with_nack(function(n2)
      seen_parent = n2.obligation.origin and n2.obligation.origin.parent_obligation == n1.obligation.id
      return Op.never()
    end)
  end)
  local view = View.open('memo-nested-view')
  assert_status(Frontier.expand_in_search(op, { id = 'memo-nested-attempt' }, view), 'found')
  assert(seen_parent, 'nested with_nack occurrence should include parent obligation identity')
end

local function guard_callback_is_memoised_across_refresh()
  reset()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'memo-guard-cell')
  local ch = Channel.new('memo-guard-block')
  local calls = 0
  local got_a, got_b
  local op = Op.guard(function()
    calls = calls + 1
    return cell:get_op(Op):and_then(function(v)
      if v == 0 then return ch:get_op(Op) end
      return Op.always('ok')
    end)
  end)
  rt:spawn(function() got_a = rt:perform(op) end, 'memo-guard-root')
  rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'memo-guard-setter')
  assert_status(rt:run(), 'found')
  assert_eq(got_b, 'set')
  assert_eq(got_a, 'ok')
  assert(rt.stats.refreshes >= 1, 'test should refresh the guard root')
  assert_eq(calls, 1, 'guard callback should be forced once for the live attempt occurrence')
end

local function guard_callback_runs_again_for_new_perform_attempt()
  reset()
  local rt = Runtime.new()
  local calls = 0
  local op = Op.guard(function()
    calls = calls + 1
    return Op.always('ok')
  end)
  local a, b
  rt:spawn(function()
    a = rt:perform(op)
    b = rt:perform(op)
  end, 'memo-guard-new-attempt')
  assert_status(rt:run(), 'found')
  assert_eq(a, 'ok')
  assert_eq(b, 'ok')
  assert_eq(calls, 2, 'new perform attempt gets fresh guard memo cells')
end

return function()
  with_nack_callback_is_memoised_across_refresh()
  with_nack_callback_runs_again_for_new_perform_attempt()
  with_nack_choice_decision_prefixes_are_distinct()
  with_nack_product_lanes_are_distinct()
  nested_with_nack_identity_includes_parent_obligation()
  guard_callback_is_memoised_across_refresh()
  guard_callback_runs_again_for_new_perform_attempt()
  print('expansion memoisation tests: ok')
end
