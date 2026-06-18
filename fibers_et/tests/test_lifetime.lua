package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')

local function accept_matching(life, pred)
  return life:accept_handoff_op():and_then(function(offer)
    if pred(offer) then return fibers.always(offer) end
    return fibers.never()
  end)
end

local life = fibers.Lifetime.new('life')
assert(life.name == 'life')
assert(life:raw_region().name == 'life')
local rt = fibers.Runtime.new()
local status
rt:spawn_raw(function()
  status = rt:perform(life:state_op())
end, 'root')
local st = rt:run()
assert(st.tag == 'found' or st.tag == 'absent')
assert(status.open == true and status.sealed == false and status.settled == false)

local life_a = fibers.Lifetime.new('a')
local life_b = fibers.Lifetime.new('b')
local task, owned_a, owned_b, report
local rt2 = fibers.Runtime.new()
rt2:spawn_raw(function()
  task = rt2:perform(life_a:spawn_op(function() return 'done' end, { name = 'owned-task' }))
  owned_a = rt2:perform(life_a:owns_op(task))
  rt2:perform(life_a:handoff_op(task, life_b))
  owned_b = rt2:perform(life_b:owns_op(task))
  report = { rt2:perform(task:await_op()) }
  rt2:perform(life_b:settle_item_op(task))
  rt2:perform(life_b:close_op())
end, 'lifetime-root')
local st2 = rt2:run()
assert(st2.tag == 'found' or st2.tag == 'absent')
assert(task and owned_a == true and owned_b == true)
assert(report[1] == 'done')
assert(life_b.region.sealed == true)

local life_events = fibers.Lifetime.new('events')
local captured
local rt3 = fibers.Runtime.new()
rt3:spawn_raw(function()
  local t = rt3:perform(life_events:spawn_op(function() return 'evented' end))
  captured = rt3:perform(life_events:next_event_op())
  rt3:perform(t:await_op())
  rt3:perform(life_events:settle_item_op(t))
end, 'events-root')
local st3 = rt3:run()
assert(st3.tag == 'found' or st3.tag == 'absent')
assert(captured.type == 'admitted')
assert(captured.lifetime == life_events)
assert(captured.item_kind == 'task')
assert(rt3.published_lifetime and #rt3.published_lifetime >= 2)

local from = fibers.Lifetime.new('from')
local to = fibers.Lifetime.new('to')
local handed, accepted, to_owns
local rt4 = fibers.Runtime.new()
rt4:spawn_raw(function()
  handed = rt4:perform(from:spawn_op(function() return 'handoff' end))
  local rows = rt4:perform(fibers.tensor({
    from:offer_handoff_op(handed, to),
    to:accept_handoff_op(),
  }))
  accepted = rows[2][1]
  to_owns = rt4:perform(to:owns_op(handed))
  rt4:perform(handed:await_op())
  rt4:perform(to:settle_item_op(handed))
end, 'handoff-root')
local st4
repeat st4 = rt4:run() until st4.tag ~= 'found'
assert(st4.tag == 'absent' or st4.tag == 'idle')
assert(accepted.item == handed and accepted.from == from and accepted.to == to)
assert(to_owns == true)

-- matched accept rejects unrelated offers and accepts the selected one.
local match_from_a = fibers.Lifetime.new('match-a')
local match_from_b = fibers.Lifetime.new('match-b')
local match_to = fibers.Lifetime.new('match-to')
local task_a, task_b, rejected_result, accepted_match, owns_a_after, owns_b_after
local rt_match = fibers.Runtime.new()
rt_match:spawn_raw(function()
  task_a = rt_match:perform(match_from_a:spawn_op(function() return 'a' end, { name = 'task-a' }))
  task_b = rt_match:perform(match_from_b:spawn_op(function() return 'b' end, { name = 'task-b' }))
  rejected_result = rt_match:perform(fibers.choice(
    fibers.tensor({
      match_from_a:offer_handoff_op(task_a, match_to),
      accept_matching(match_to, function(offer) return offer.from_lifetime == match_from_b end),
    }):map(function() return 'unexpected' end),
    fibers.always('rejected')
  ))
  local rows = rt_match:perform(fibers.tensor({
    match_from_b:offer_handoff_op(task_b, match_to),
    accept_matching(match_to, function(offer) return offer.from_lifetime == match_from_b and offer.item_kind == 'task' end),
  }))
  accepted_match = rows[2][1]
  owns_a_after = rt_match:perform(match_from_a:owns_op(task_a))
  owns_b_after = rt_match:perform(match_to:owns_op(task_b))
  rt_match:perform(task_a:await_op())
  rt_match:perform(task_b:await_op())
  rt_match:perform(match_from_a:settle_item_op(task_a))
  rt_match:perform(match_to:settle_item_op(task_b))
end, 'matched-handoff-root')
local st_match
repeat st_match = rt_match:run() until st_match.tag ~= 'found'
assert(st_match.tag == 'absent' or st_match.tag == 'idle')
assert(rejected_result == 'rejected')
assert(accepted_match.item == task_b)
assert(accepted_match.from == match_from_b)
assert(owns_a_after == true)
assert(owns_b_after == true)

-- lifetime settlement is a terminal transition: sealed and empty only.
local settle_life = fibers.Lifetime.new('settle-life')
local settle_task, before_release, settled_status, duplicate_settle
local rt_settle = fibers.Runtime.new()
rt_settle:spawn_raw(function()
  settle_task = rt_settle:perform(settle_life:spawn_op(function() return 'settle' end))
  rt_settle:perform(settle_task:await_op())
  rt_settle:perform(settle_life:close_op('done'))
  before_release = rt_settle:perform(fibers.choice(
    settle_life:settle_op():map(function() return 'unexpected' end),
    fibers.always('not-empty')
  ))
  rt_settle:perform(settle_life:settle_item_op(settle_task))
  rt_settle:perform(settle_life:settle_op())
  settled_status = rt_settle:perform(settle_life:state_op())
  duplicate_settle = rt_settle:perform(fibers.choice(
    settle_life:settle_op():map(function() return 'unexpected' end),
    fibers.always('already-settled')
  ))
end, 'settle-root')
local st_settle
repeat st_settle = rt_settle:run() until st_settle.tag ~= 'found'
assert(st_settle.tag == 'absent' or st_settle.tag == 'idle')
assert(before_release == 'not-empty')
assert(settled_status.settled == true and settled_status.phase == 'settled')
assert(duplicate_settle == 'already-settled')

print('tests/test_lifetime.lua: ok')
