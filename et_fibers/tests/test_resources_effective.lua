package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Cell = require('et.resources.cell')
local Queue = require('et.resources.queue')
local Channel = require('et.resources.channel')

local function assert_eq(actual, expected, msg)
  if actual ~= expected then error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end

local function assert_status(x, tag, msg)
  if not x or x.tag ~= tag then error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end
end

local function assert_list(xs, expected, msg)
  if #xs ~= #expected then error((msg or 'list length') .. ': expected ' .. #expected .. ', got ' .. #xs, 2) end
  for i = 1, #expected do
    if xs[i] ~= expected[i] then error((msg or 'list item') .. '[' .. i .. ']: expected ' .. tostring(expected[i]) .. ', got ' .. tostring(xs[i]), 2) end
  end
end

local function test_channel_lives_under_resources_only()
  assert_eq(require('et.resources.channel') == Channel, true, 'channel module available under resources')
  local ok = pcall(function() return require('et.channel') end)
  assert_eq(ok, false, 'old et.channel module has been removed')
  local old_op_ok = pcall(function() return require('et.tx') end)
  assert_eq(old_op_ok, false, 'old et.tx module has been removed')
  assert_eq(require('et.op') == Op, true, 'Op module is the public transactional operation module')
  local rt = Runtime.new()
  local ch = Channel.new('resources-channel')
  assert_eq(ch.send_op, nil, 'old channel send_op method has been removed')
  assert_eq(ch.recv_op, nil, 'old channel recv_op method has been removed')
  local got
  rt:spawn(function() rt:perform(ch:put_op(Op, 'payload')) end, 'channel-send')
  rt:spawn(function() got = rt:perform(ch:get_op(Op)) end, 'channel-recv')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
end

local function test_cell_sequential_update_and_retry()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'effective-cell')
  local a, b, final
  rt:spawn(function() a = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-a')
  rt:spawn(function() b = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-b')
  rt:spawn(function() final = rt:perform(cell:get_op(Op)) end, 'cell-get')
  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'contending effective cell updates both complete')
  assert_eq(a, 1)
  assert_eq(b, 2)
  assert_eq(final, 2)
end

local function test_queue_sequential_push_pop_in_one_transaction()
  local rt = Runtime.new()
  local q = Queue.new({}, 'q-seq')
  local popped, length
  rt:spawn(function()
    popped = rt:perform(q:push_op(Op, 'a'):and_then(function()
      return q:push_op(Op, 'b'):and_then(function()
        return q:pop_op(Op)
      end)
    end))
  end, 'queue-seq')
  rt:spawn(function() length = rt:perform(q:length_op(Op)) end, 'queue-len')
  assert_status(rt:run(), 'found')
  assert_eq(popped, 'a')
  assert_list(q:to_table(), { 'b' }, 'queue final state')
  assert_eq(length, 1, 'length sees committed final state after retry')
end

local function test_queue_contending_pops_retry()
  local rt = Runtime.new()
  local q = Queue.new({ 'a', 'b' }, 'q-contended')
  local one, two
  rt:spawn(function() one = rt:perform(q:pop_op(Op)) end, 'queue-pop-one')
  rt:spawn(function() two = rt:perform(q:pop_op(Op)) end, 'queue-pop-two')
  assert_status(rt:run(), 'found')
  assert_eq(one, 'a')
  assert_eq(two, 'b')
  assert_list(q:to_table(), {}, 'queue consumed both initial items')
  assert(rt.stats.refreshes >= 1, 'second queue pop refreshed after first pop dirtied queue')
end

local function test_queue_external_pop_wait()
  local host_counts = { watches = 0, unwatches = 0 }
  local rt = Runtime.new({ quiet_deadlock = true, host = {
    watch = function() host_counts.watches = host_counts.watches + 1; return require('et.machine.kernel').Status.found(true) end,
    unwatch = function() host_counts.unwatches = host_counts.unwatches + 1; return require('et.machine.kernel').Status.found(true) end,
  } })
  local q = Queue.new({}, 'q-wait')
  local got
  rt:spawn(function() got = rt:perform(q:pop_wait_op(Op)) end, 'queue-wait-pop')
  local first = rt:run()
  assert_eq(first.tag, 'pending', 'empty queue wait is pending, not deadlock')
  assert_eq(host_counts.watches, 1)
  q:force_push('external')
  rt:mark_dirty({ q }, 'external queue push')
  local second = rt:run()
  assert_status(second, 'found')
  assert_eq(got, 'external')
  assert_list(q:to_table(), {}, 'external item consumed')
  assert(host_counts.unwatches >= 1, 'external wait was unwatched during refresh/commit')
end

local function test_parallel_queue_edits_conflict_but_identical_reads_compose()
  local rt = Runtime.new({ quiet_deadlock = true })
  local q = Queue.new({}, 'q-conflict')
  local got
  rt:spawn(function()
    got = rt:perform(Op.tensor({ q:push_op(Op, 'a'), q:push_op(Op, 'b') }))
  end, 'queue-parallel-conflict')
  local st = rt:run()
  assert(st.tag == 'absent' or st.tag == 'conflict', 'parallel distinct queue writes do not silently choose an order')
  assert_eq(got, nil)
  assert_list(q:to_table(), {}, 'conflicting transaction did not commit')

  local rt2 = Runtime.new()
  local q2 = Queue.new({ 'z' }, 'q-peek')
  local pair
  rt2:spawn(function()
    pair = rt2:perform(Op.tensor({ q2:peek_op(Op), q2:length_op(Op) }))
  end, 'queue-parallel-read')
  assert_status(rt2:run(), 'found')
  assert_eq(pair[1][1], 'z')
  assert_eq(pair[2][1], 1)
  assert_list(q2:to_table(), { 'z' })
end

return function()
  test_channel_lives_under_resources_only()
  test_cell_sequential_update_and_retry()
  test_queue_sequential_push_pop_in_one_transaction()
  test_queue_contending_pops_retry()
  test_queue_external_pop_wait()
  test_parallel_queue_edits_conflict_but_identical_reads_compose()
  print('effective resource tests: ok')
end
