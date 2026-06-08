package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')

local life = fibers.Lifetime.new('life')
assert(life.name == 'life')
assert(life:raw_region().name == 'life')
local rt = fibers.Runtime.new()
local status
rt:spawn_raw(function()
  status = rt:perform(life:status_op())
end, 'root')
local st = rt:run()
assert(st.tag == 'found' or st.tag == 'absent')
assert(status.open == true and status.sealed == false)


local life_a = fibers.Lifetime.new('a')
local life_b = fibers.Lifetime.new('b')
local task, owned_a, owned_b, report
local rt2 = fibers.Runtime.new()
rt2:spawn_raw(function()
  task = rt2:perform(life_a:spawn_op(function() return 'done' end, { name = 'owned-task' }))
  owned_a = rt2:perform(life_a:owns_op(task))
  rt2:perform(life_a:transfer_op(task, life_b))
  owned_b = rt2:perform(life_b:owns_op(task))
  report = { rt2:perform(task:join_op()) }
  rt2:perform(life_b:release_op(task))
  rt2:perform(life_b:seal_op())
end, 'lifetime-root')
local st2 = rt2:run()
assert(st2.tag == 'found' or st2.tag == 'absent')
assert(task and owned_a == true and owned_b == true)
assert(report[1] == 'ok')
assert(report[2] == 'done')
assert(life_b.region.sealed == true)


local life_events = fibers.Lifetime.new('events')
local captured
local rt3 = fibers.Runtime.new()
rt3:spawn_raw(function()
  local t = rt3:perform(life_events:spawn_op(function() return 'evented' end))
  captured = rt3:perform(life_events:watch_op())
  rt3:perform(t:join_op())
  rt3:perform(life_events:release_op(t))
end, 'events-root')
local st3 = rt3:run()
assert(st3.tag == 'found' or st3.tag == 'absent')
assert(captured.type == 'task_admitted')
assert(captured.lifetime == life_events)
assert(rt3.published_lifetime and #rt3.published_lifetime >= 2)


local from = fibers.Lifetime.new('from')
local to = fibers.Lifetime.new('to')
local handed, accepted, to_owns
local rt4 = fibers.Runtime.new()
rt4:spawn_raw(function()
  handed = rt4:perform(from:spawn_op(function() return 'handoff' end))
  local rows = rt4:perform(fibers.tensor({
    from:offer_op(handed, to),
    to:accept_op(),
  }))
  accepted = rows[2][1]
  to_owns = rt4:perform(to:owns_op(handed))
  rt4:perform(handed:join_op())
  rt4:perform(to:release_op(handed))
end, 'handoff-root')
local st4
repeat st4 = rt4:run() until st4.tag ~= 'found'
assert(st4.tag == 'absent' or st4.tag == 'idle')
assert(accepted.item == handed and accepted.from == from and accepted.to == to)
assert(to_owns == true)

print('tests/test_lifetime.lua: ok')
