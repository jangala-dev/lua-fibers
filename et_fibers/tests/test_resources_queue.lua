package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
local Op = require('et.op')
local Runtime = require('et.runtime')
local Queue = require('et.resources.queue')
local Status = require('et.kernel').Status
local function assert_eq(a,b,m) if a~=b then error((m or 'assert_eq')..': expected '..tostring(b)..', got '..tostring(a),2) end end
local function assert_status(x,tag,m) if not x or x.tag~=tag then error((m or 'status')..': expected '..tag..', got '..tostring(x and x.tag),2) end end
local function assert_list(xs, expected, msg) if #xs ~= #expected then error((msg or 'list length') .. ': expected ' .. #expected .. ', got ' .. #xs, 2) end; for i=1,#expected do if xs[i] ~= expected[i] then error((msg or 'list item')..'['..i..']: expected '..tostring(expected[i])..', got '..tostring(xs[i]),2) end end end
return function()
  local rt = Runtime.new()
  local q = Queue.new({}, 'q-seq')
  local popped, length
  rt:spawn(function()
    popped = rt:perform(q:push_op(Op, 'a'):and_then(function()
      return q:push_op(Op, 'b'):and_then(function() return q:pop_op(Op) end)
    end))
  end, 'queue-seq')
  rt:spawn(function() length = rt:perform(q:length_op(Op)) end, 'queue-len')
  assert_status(rt:run(), 'found')
  assert_eq(popped, 'a')
  assert_list(q:to_table(), { 'b' }, 'queue final state')
  assert_eq(length, 1, 'length sees committed final state after retry')

  local rt2 = Runtime.new()
  local q2 = Queue.new({ 'a', 'b' }, 'q-contended')
  local one, two
  rt2:spawn(function() one = rt2:perform(q2:pop_op(Op)) end, 'queue-pop-one')
  rt2:spawn(function() two = rt2:perform(q2:pop_op(Op)) end, 'queue-pop-two')
  assert_status(rt2:run(), 'found')
  assert_eq(one, 'a')
  assert_eq(two, 'b')
  assert_list(q2:to_table(), {}, 'queue consumed both initial items')
  assert(rt2.stats.refreshes >= 1, 'second queue pop refreshed after first pop dirtied queue')

  local host_counts = { watches = 0, unwatches = 0 }
  local rt3 = Runtime.new({ quiet_deadlock = true, host = {
    watch = function() host_counts.watches = host_counts.watches + 1; return Status.found(true) end,
    unwatch = function() host_counts.unwatches = host_counts.unwatches + 1; return Status.found(true) end,
  } })
  local q3 = Queue.new({}, 'q-wait')
  local got
  rt3:spawn(function() got = rt3:perform(q3:pop_wait_op(Op)) end, 'queue-wait-pop')
  local first = rt3:run()
  assert_eq(first.tag, 'pending', 'empty queue wait is pending, not deadlock')
  assert_eq(host_counts.watches, 1)
  q3:force_push('external')
  rt3:mark_dirty({ q3 }, 'external queue push')
  assert_status(rt3:run(), 'found')
  assert_eq(got, 'external')
  assert_list(q3:to_table(), {}, 'external item consumed')
  assert(host_counts.unwatches >= 1, 'external wait was unwatched during refresh/commit')

  local rt4 = Runtime.new({ quiet_deadlock = true })
  local q4 = Queue.new({}, 'q-conflict')
  local pair
  rt4:spawn(function() pair = rt4:perform(Op.tensor({ q4:push_op(Op, 'a'), q4:push_op(Op, 'b') })) end, 'queue-parallel-conflict')
  local st = rt4:run()
  assert(st.tag == 'absent' or st.tag == 'conflict', 'parallel distinct queue writes do not silently choose an order')
  assert_eq(pair, nil)
  assert_list(q4:to_table(), {}, 'conflicting transaction did not commit')

  local rt5 = Runtime.new()
  local q5 = Queue.new({ 'z' }, 'q-peek')
  rt5:spawn(function() pair = rt5:perform(Op.tensor({ q5:peek_op(Op), q5:length_op(Op) })) end, 'queue-parallel-read')
  assert_status(rt5:run(), 'found')
  assert_eq(pair[1][1], 'z')
  assert_eq(pair[2][1], 1)
  assert_list(q5:to_table(), { 'z' })
  print('resources/queue tests: ok')
end
