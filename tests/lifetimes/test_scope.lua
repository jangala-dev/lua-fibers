package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersScope = require('fibers.scope')
local Closure = require('fibers.closure')

local function accept_matching(life, pred)
  return life:accept_op():and_then(Op.guard(function(offer)
    if pred(offer) then
      return Op.always(offer)
    end
    return Op.never()
  end))
end

local function retire(rt, scope, item, reason)
  return rt:perform(Closure.close_op(scope, item, reason or 'done'))
end

local life = FibersScope.new():label('life')
assert(life:label() == 'life')
assert(life:lifetime():label() == 'life')
local rt = FibersRuntime.new()
local status
rt:spawn_raw(function()
  status = rt:perform(life:inspect_op())
end):label('root')
local st = rt:run()
assert(st.tag == 'found' or st.tag == 'quiescent')
assert(status.open == true and status.sealed == false and status.done == false)

local life_a = FibersScope.new():label('a')
local life_b = FibersScope.new():label('b')
local task, owned_a, owned_b, report
local rt2 = FibersRuntime.new()
rt2:spawn_raw(function()
  task = rt2:perform(life_a:spawn_op(function()
    return 'done'
  end, { label = 'owned-task' }))
  owned_a = rt2:perform(life_a:has_custody_op(task))
  rt2:perform(life_a:move_op(task, life_b))
  owned_b = rt2:perform(life_b:has_custody_op(task))
  report = { rt2:perform(task:await_op()) }
  retire(rt2, life_b, task)
  rt2:perform(life_b:seal_op())
  status = rt2:perform(life_b:inspect_op())
end):label('scope-root')
local st2 = rt2:run()
assert(st2.tag == 'found' or st2.tag == 'quiescent')
assert(task and owned_a == true and owned_b == true)
assert(report[1] == 'done')
assert(status.sealed == true)

local from = FibersScope.new():label('from')
local to = FibersScope.new():label('to')
local handed, accepted, to_owns
local rt4 = FibersRuntime.new()
rt4:spawn_raw(function()
  handed = rt4:perform(from:spawn_op(function()
    return 'custody-transfer'
  end))
  local rows = rt4:perform(Op.together({
    from:offer_op(handed, to),
    to:accept_op(),
  }))
  accepted = rows[2][1]
  to_owns = rt4:perform(to:has_custody_op(handed))
  rt4:perform(handed:await_op())
  retire(rt4, to, handed)
end):label('custody-transfer-root')
local st4
repeat
  st4 = rt4:run()
until st4.tag ~= 'found'
assert(st4.tag == 'quiescent' or st4.tag == 'idle')
assert(accepted.item == handed and accepted.from_scope == from and accepted.to_scope == to)
assert(to_owns == true)

-- matched accept rejects unrelated offers and accepts the selected one.
local match_from_a = FibersScope.new():label('match-a')
local match_from_b = FibersScope.new():label('match-b')
local match_to = FibersScope.new():label('match-to')
local task_a, task_b, rejected_result, accepted_match, owns_a_after, owns_b_after
local rt_match = FibersRuntime.new()
rt_match:spawn_raw(function()
  task_a = rt_match:perform(match_from_a:spawn_op(function()
    return 'a'
  end, { label = 'task-a' }))
  task_b = rt_match:perform(match_from_b:spawn_op(function()
    return 'b'
  end, { label = 'task-b' }))
  rejected_result = rt_match:perform(Op.together({
    match_from_a:offer_op(task_a, match_to),
    accept_matching(match_to, function(offer)
      return offer.from_scope == match_from_b
    end),
  })
    :map(function()
      return 'unexpected'
    end)
    :or_else(Op.always('rejected')))
  local rows = rt_match:perform(Op.together({
    match_from_b:offer_op(task_b, match_to),
    accept_matching(match_to, function(offer)
      return offer.from_scope == match_from_b and offer.item_kind == 'task'
    end),
  }))
  accepted_match = rows[2][1]
  -- debug
  -- print('rows2', rows[2], rows[2] and rows[2][1])
  owns_a_after = rt_match:perform(match_from_a:has_custody_op(task_a))
  owns_b_after = rt_match:perform(match_to:has_custody_op(task_b))
  rt_match:perform(task_a:await_op())
  rt_match:perform(task_b:await_op())
  retire(rt_match, match_from_a, task_a)
  retire(rt_match, match_to, task_b)
end):label('matched-custody-offer-root')
local st_match
repeat
  st_match = rt_match:run()
until st_match.tag ~= 'found'
assert(st_match.tag == 'quiescent' or st_match.tag == 'idle')
assert(rejected_result == 'rejected')
assert(accepted_match.item == task_b)
assert(accepted_match.from_scope == match_from_b)
assert(owns_a_after == true)
assert(owns_b_after == true)

-- done_op is a boundary fact created by Scope:run.
do
  local done_scope
  local done_outcome
  local a, b = fibers.run(function()
    local result = fibers.try_scope(function(s)
      done_scope = s
      return 'scope-value', nil, 'tail'
    end)
    assert(result.ok == true)
    local x, y, z = result:unpack()
    assert(x == 'scope-value' and y == nil and z == 'tail')
    done_outcome = fibers.perform(done_scope:done_op())
    return 'root-value', 'root-tail'
  end)
  assert(a == 'root-value' and b == 'root-tail')
  assert(done_outcome.ok == true)
end

-- Filtered accept is transactional: a rejected offer rejects that world rather
-- than consuming and discarding the wrong custody offer.
do
  local from_a = FibersScope.new():label('filter-a')
  local from_b = FibersScope.new():label('filter-b')
  local to = FibersScope.new():label('filter-to')
  local task_a, task_b, both_result, accepted_b, a_still_owned, b_moved
  local rt_filter = FibersRuntime.new()
  rt_filter:spawn_raw(function()
    task_a = rt_filter:perform(from_a:spawn_op(function()
      return 'a'
    end, { label = 'filter-task-a' }))
    task_b = rt_filter:perform(from_b:spawn_op(function()
      return 'b'
    end, { label = 'filter-task-b' }))
    both_result = rt_filter:perform(Op.together({
      from_a:offer_op(task_a, to),
      from_b:offer_op(task_b, to),
      to:accept_op(function(offer)
        return offer.from_scope == from_b
      end),
    })
      :map(function()
        return 'unexpected'
      end)
      :or_else(Op.always('blocked')))
    local rows = rt_filter:perform(Op.together({
      from_b:offer_op(task_b, to),
      to:accept_op(function(offer)
        return offer.from_scope == from_b
      end),
    }))
    accepted_b = rows[2][1]
    a_still_owned = rt_filter:perform(from_a:has_custody_op(task_a))
    b_moved = rt_filter:perform(to:has_custody_op(task_b))
    rt_filter:perform(task_a:await_op())
    rt_filter:perform(task_b:await_op())
    retire(rt_filter, from_a, task_a)
    retire(rt_filter, to, task_b)
  end):label('filtered-accept-root')
  local st_filter
  repeat
    st_filter = rt_filter:run()
  until st_filter.tag ~= 'found'
  assert(st_filter.tag == 'quiescent' or st_filter.tag == 'idle')
  assert(both_result == 'blocked')
  assert(accepted_b.item == task_b)
  assert(a_still_owned == true)
  assert(b_moved == true)
end

print('tests/test_scope.lua: ok')
