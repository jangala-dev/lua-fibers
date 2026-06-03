local core = require('etfcore')
local Op = core.Op
local Runtime = require('runtime').Runtime

local Channel = require('resources.channel')
local Cell = require('resources.cell')
local Queue = require('resources.queue')
local Log = require('resources.log')
local Signal = require('resources.signal')
local Clock = require('resources.clock')
local Ledger = require('ledger')

local test_cases = {}

local function test(name, fn)
  test_cases[#test_cases + 1] = { name = name, fn = fn }
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assertion failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function silence_commit_events(fn)
  local old_new = Runtime.new
  Runtime.new = function(opts)
    opts = opts or {}
    if opts.on_descriptor == nil then
      opts.on_descriptor = function(_) end
    end
    return old_new(opts)
  end
  local ok, err = pcall(fn)
  Runtime.new = old_new
  if not ok then error(err, 0) end
end

test('channel exposes only _op operation constructors', function()
  local ch = Channel.new('resource-channel-api')
  assert(type(ch.put_op) == 'function', 'put_op should exist')
  assert(type(ch.get_op) == 'function', 'get_op should exist')
  assert(ch.put == nil, 'old put alias should not exist')
  assert(ch.get == nil, 'old get alias should not exist')
end)

test('channel put_op/get_op rendezvous', function()
  local rt = Runtime.new()
  local ch = Channel.new('resource-channel')
  local got

  rt:spawn(function() Op.perform(ch:put_op('hello')) end, 'putter')
  rt:spawn(function() got = Op.perform(ch:get_op()) end, 'getter')
  rt:run()

  assert_eq(got, 'hello', 'channel get should receive put value')
end)

test('cell get_op/set_op/update_op commit transactionally', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local cell = Cell.new(1, 'resource-cell')
    local before, after

    rt:spawn(function()
      before = Op.perform(cell:get_op())
      Op.perform(cell:update_op(function(v) return v + 41 end))
      after = Op.perform(cell:get_op())
    end, 'cell-user')
    rt:run()

    assert_eq(before, 1, 'cell should read initial value')
    assert_eq(after, 42, 'cell should read updated value')
    assert_eq(cell.value, 42, 'cell update should commit')
  end)
end)

test('cell losing branch does not leak write', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local cell = Cell.new('old', 'resource-cell-discard')
    local result

    rt:spawn(function()
      result = Op.perform(Op.choice(
        cell:set_op('bad'):and_then(function() return Op.never() end),
        Op.always('ok')
      ))
    end, 'cell-choice')
    rt:run()

    assert_eq(result, 'ok', 'fallback branch should commit')
    assert_eq(cell.value, 'old', 'losing write should be discarded')
  end)
end)

test('queue put_op/get_op preserve ordered transactional state', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local q = Queue.new({ 'a' }, 'resource-queue')
    local first, second

    rt:spawn(function()
      first = Op.perform(q:put_op('b'):and_then(function()
        return q:get_op()
      end))
      second = Op.perform(q:get_op())
    end, 'queue-user')
    rt:run()

    assert_eq(first, 'a', 'queue should pop initial head')
    assert_eq(second, 'b', 'queue should later pop committed append')
    assert_eq(#q.items, 0, 'queue should be empty')
  end)
end)

test('queue conflicting product edits do not choose an implicit order', function()
  local rt = Runtime.new()
  local q = Queue.new({}, 'resource-queue-conflict')

  local task = rt:spawn(function()
    Op.perform(Op.tensor({ q:put_op('a'), q:put_op('b') }))
  end, 'queue-conflict')

  rt:resume_task(task)
  local result = rt:search_task(task)

  assert_eq(result.status, 'absent', 'conflicting queue product edits should be absent')
  assert_eq(#q.items, 0, 'conflicting queue edits should not commit')
end)

test('log append_op returns offsets and read_from_op sees tentative appends', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local log = Log.new({}, 'resource-log')
    local offset1, offset2, records

    rt:spawn(function()
      local packed = Op.perform(log:append_op('a'):and_then(function(o1)
        return log:append_op('b'):and_then(function(o2)
          return log:read_from_op(1):map(function(rs)
            return { o1, o2, rs }
          end)
        end)
      end))
      offset1, offset2, records = packed[1], packed[2], packed[3]
    end, 'log-user')
    rt:run()

    assert_eq(offset1, 1, 'first append offset')
    assert_eq(offset2, 2, 'second append offset')
    assert_eq(records[1], 'a', 'read should see first tentative append')
    assert_eq(records[2], 'b', 'read should see second tentative append')
    assert_eq(log.records[1], 'a', 'first append should commit')
    assert_eq(log.records[2], 'b', 'second append should commit')
  end)
end)

test('signal wake_op can commit without waiter and advances cursor', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local sig = Signal.new('resource-signal-alone')
    local cursor = sig:cursor()
    local woke, observed

    rt:spawn(function() woke = Op.perform(sig:wake_op()) end, 'signal-waker')
    rt:run()

    assert_eq(woke, true, 'wake should commit')
    assert(sig:cursor() > cursor, 'wake should advance cursor')

    rt:spawn(function() observed = Op.perform(sig:wait_op(cursor)) end, 'signal-prior-waiter')
    rt:run()
    assert_eq(observed, true, 'wait should close after prior wake')
  end)
end)

test('signal wait_op can rendezvous with wake_op in one commit', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local sig = Signal.new('resource-signal-rendezvous')
    local cursor = sig:cursor()
    local waited, woke

    rt:spawn(function() waited = Op.perform(sig:wait_op(cursor)) end, 'signal-waiter')
    rt:spawn(function() woke = Op.perform(sig:wake_op()) end, 'signal-waker')
    rt:run()

    assert_eq(waited, true, 'waiter should resume')
    assert_eq(woke, true, 'waker should resume')
    assert(sig:cursor() > cursor, 'wake should advance cursor')
  end)
end)



test('clock sleep_until_op waits for external deadline and then commits', function()
  local rt = Runtime.new()
  local now = 0
  local clock = Clock.new(rt, {
    now_fn = function() return now end,
    sleep_fn = function(dt) now = now + dt end,
  })
  local done_at

  rt:spawn(function()
    Op.perform(clock:sleep_until_op(5))
    done_at = now
  end, 'clock-sleeper')
  rt:run()

  assert_eq(done_at, 5, 'runtime should wait until deadline')
end)

test('clock sleep_op fixes relative deadline at attempt time', function()
  local rt = Runtime.new()
  local now = 10
  local clock = Clock.new(rt, {
    now_fn = function() return now end,
    sleep_fn = function(dt) now = now + dt end,
  })
  local constructed = clock:sleep_op(7)
  local done_at

  now = 20
  rt:spawn(function()
    Op.perform(constructed)
    done_at = now
  end, 'relative-clock-sleeper')
  rt:run()

  assert_eq(done_at, 27, 'relative sleep should be measured from perform attempt')
end)

test('clock sleep_op guard memoises deadline across proof replay', function()
  local rt = Runtime.new()
  local now = 100
  local clock = Clock.new(rt, {
    now_fn = function() return now end,
    sleep_fn = function(dt) now = now + dt end,
  })
  local calls = 0
  local done_at

  local op = Op.guard(function()
    calls = calls + 1
    return clock:sleep_until_op(clock:now() + 3)
  end)

  rt:spawn(function()
    Op.perform(op)
    done_at = now
  end, 'memo-clock-sleeper')

  local task = table.remove(rt.runnable, 1)
  rt:resume_task(task)
  local first = rt:search_task(task)
  assert_eq(first.status, 'absent', 'sleep should not be ready before deadline')
  local second = rt:search_task(task)
  assert_eq(second.status, 'absent', 'replayed search should still be absent')
  assert_eq(calls, 1, 'guard should run once for the parked attempt')

  now = 103
  rt:run()
  assert_eq(done_at, 103, 'sleep should finish at memoised deadline')
end)

test('external await publishes only retained frontier waits', function()
  local published = 0
  local unpublished = 0
  local ready = false

  local Resource = {}
  function Resource:ready(_request, _runtime)
    if ready then return true, { value = true } end
    return false
  end
  function Resource:publish_wait(_runtime, _attempt, _frame)
    published = published + 1
    return { id = published }
  end
  function Resource:unpublish_wait(_runtime, _token)
    unpublished = unpublished + 1
  end

  local rt = Runtime.new()
  local op = Op.choice(
    Op.await(Resource, { tag = 'external' }):and_then(function() return Op.never() end),
    Op.always('fallback')
  )
  local result

  rt:spawn(function()
    result = Op.perform(op)
  end, 'external-publication')
  rt:run()

  assert_eq(result, 'fallback', 'fallback should commit')
  assert_eq(published, 1, 'retained await frame should be published once')
  assert_eq(unpublished, 1, 'published external wait should be unpublished on commit')
end)


test('external await reached only by candidate bind is not published', function()
  local published = 0
  local Resource = {}
  function Resource:ready(_request, _runtime) return false end
  function Resource:publish_wait(_runtime, _attempt, _frame)
    published = published + 1
    return { id = published }
  end

  local rt = Runtime.new()
  local op = Op.choice(
    Op.always('candidate'):and_then(function()
      return Op.await(Resource, { tag = 'candidate-only' })
    end),
    Op.always('fallback')
  )
  local result

  rt:spawn(function()
    result = Op.perform(op)
  end, 'external-candidate-only')
  rt:run()

  assert_eq(result, 'fallback', 'fallback should commit')
  assert_eq(published, 0, 'candidate-only await should not publish')
end)

test('clock withdrawal unpublishes retained timer wait', function()
  local rt = Runtime.new()
  local now = 0
  local clock = Clock.new(rt, { now_fn = function() return now end })

  rt:spawn(function()
    Op.perform(clock:sleep_until_op(10))
  end, 'withdrawn-clock-sleeper')

  local task = table.remove(rt.runnable, 1)
  rt:resume_task(task)
  assert_eq(#clock.waits, 1, 'sleep should publish one timer')

  local ok, reason = rt:withdraw_attempt(task.attempt, 'test-withdraw')
  if not ok then error(reason or 'withdraw failed') end
  clock:next_deadline(rt) -- prune cancelled token
  assert_eq(#clock.waits, 0, 'withdraw should unpublish timer')
end)

test('clock external await works inside tensor and all lanes', function()
  local rt = Runtime.new()
  local now = 0
  local clock = Clock.new(rt, {
    now_fn = function() return now end,
    sleep_fn = function(dt) now = now + dt end,
  })
  local tensor_done, all_done

  rt:spawn(function()
    Op.perform(Op.tensor({ clock:sleep_until_op(2), Op.always(true) }))
    tensor_done = now
  end, 'clock-tensor')
  rt:run()
  assert_eq(tensor_done, 2, 'tensor lane sleep should close after deadline')

  now = 10
  rt:spawn(function()
    Op.perform(Op.all({ clock:sleep_until_op(15), Op.always(true) }))
    all_done = now
  end, 'clock-all')
  rt:run()
  assert_eq(all_done, 15, 'all lane sleep should close after deadline')
end)


test('ledger is derived from primitive resources and preserves transactional state', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local ledger = Ledger.new({ ticket = 'A' }, 'resource-derived-ledger')
    local changed_cursor = ledger:change_cursor()
    local moved, closed, observed_change

    rt:spawn(function()
      moved = Op.perform(ledger:move_op('ticket', 'A', 'B'):and_then(function()
        return ledger:close_op('A', 'moved-out')
      end))
    end, 'derived-ledger-user')
    rt:run()

    assert_eq(moved, true, 'derived ledger move+close should commit')
    assert_eq(ledger.owners.ticket, 'B', 'owner should move through owners Cell')
    assert_eq(ledger.closed.A, 'moved-out', 'closed owner should commit through closed Cell')
    assert_eq(ledger.events[1].tag, 'ledger.move', 'move should append to primitive Log')
    assert_eq(ledger.events[2].tag, 'ledger.close', 'close should append to primitive Log')

    rt:spawn(function()
      observed_change = Op.perform(ledger:changed_op(changed_cursor))
    end, 'derived-ledger-waiter')
    rt:run()
    assert_eq(observed_change, true, 'derived ledger should signal committed changes')

    rt:spawn(function()
      closed = Op.perform(ledger:closed_op('A'))
    end, 'derived-ledger-reader')
    rt:run()
    assert_eq(closed, 'moved-out', 'closed_op should be a transactional read protocol')
  end)
end)

test('ledger losing branch does not leak primitive log, signal, or state changes', function()
  silence_commit_events(function()
    local rt = Runtime.new()
    local ledger = Ledger.new({ ticket = 'A' }, 'resource-derived-ledger-loss')
    local cursor = ledger:change_cursor()
    local result

    rt:spawn(function()
      result = Op.perform(Op.choice(
        ledger:move_op('ticket', 'A', 'B'):and_then(function() return Op.never() end),
        Op.always('fallback')
      ))
    end, 'derived-ledger-loss-user')
    rt:run()

    assert_eq(result, 'fallback', 'fallback should commit')
    assert_eq(ledger.owners.ticket, 'A', 'losing ledger owner update should be discarded')
    assert_eq(#ledger.events, 0, 'losing ledger log append should be discarded')
    assert_eq(ledger:change_cursor(), cursor, 'losing ledger signal wake should be discarded')
  end)
end)


test('runtime exposes bounded step API for embedded hosts', function()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ch = Channel.new('step-api')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get_op())
  end, 'step-receiver')

  local s1 = rt:step({ resume_budget = 1 })
  assert_eq(s1.status, 'resumed', 'first step should resume one runnable fibre')
  assert_eq(#rt.waiting, 1, 'receiver should be parked after bounded resume')

  local s2 = rt:step()
  assert_eq(s2.status, 'deadlock', 'parked receiver with no sender should report deadlock without blocking')

  rt:spawn(function()
    Op.perform(ch:put_op('value'))
  end, 'step-sender')

  local s3 = rt:step({ resume_budget = 1 })
  assert_eq(s3.status, 'resumed', 'sender step should park sender')

  local s4 = rt:step({ commit_budget = 1 })
  assert_eq(s4.status, 'committed', 'step should be able to commit one world')

  local s5 = rt:step({ resume_budget = 2 })
  assert_eq(s5.status, 'resumed', 'resumed committed tasks should run in bounded step')
  assert_eq(got, 'value', 'step API should preserve committed result')
end)

test('runtime descriptor handler is per-runtime', function()
  local events1, events2 = {}, {}
  local rt1 = Runtime.new({ on_descriptor = function(ev) events1[#events1 + 1] = ev.tag end })
  local rt2 = Runtime.new({ on_descriptor = function(ev) events2[#events2 + 1] = ev.tag end })

  rt1:spawn(function() Op.perform(Op.emit({ tag = 'rt1.event' })) end, 'descriptor-1')
  rt2:spawn(function() Op.perform(Op.emit({ tag = 'rt2.event' })) end, 'descriptor-2')

  rt1:run()
  rt2:run()

  assert_eq(events1[1], 'rt1.event', 'first runtime should receive its own descriptor')
  assert_eq(events2[1], 'rt2.event', 'second runtime should receive its own descriptor')
end)

local M = {}

function M.run_tests()
  for _, case in ipairs(test_cases) do
    case.fn()
  end
  print('resource primitive tests: channel, cell, queue, log, signal, clock, and derived ledger passed')
end

return M
