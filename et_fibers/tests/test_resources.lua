local core = require('etfcore')
local Op = core.Op
local Runtime = core.Runtime

local Channel = require('resources.channel')
local Cell = require('resources.cell')
local Queue = require('resources.queue')
local Log = require('resources.log')
local Signal = require('resources.signal')
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
  local old = core.print_event
  core.print_event = function(_) end
  local ok, err = pcall(fn)
  core.print_event = old
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

local M = {}

function M.run_tests()
  for _, case in ipairs(test_cases) do
    case.fn()
  end
  print('resource primitive tests: channel, cell, queue, log, signal, and derived ledger passed')
end

return M
