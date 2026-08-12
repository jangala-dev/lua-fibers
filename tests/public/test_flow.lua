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
local Runtime = require('fibers.runtime')
local Flow = require('fibers.resource.flow')
local Errors = require('fibers.resource.flow.errors')

local function fail(msg)
  error(msg, 2)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

local function assert_nil(v, msg)
  if v ~= nil then
    fail((msg or 'expected nil') .. ': got ' .. tostring(v))
  end
end

local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end

local function drive_until(rt, pred, label)
  for _ = 1, 120 do
    if pred() then
      return true
    end
    rt:step()
  end
  fail(label or 'runtime did not reach expected state')
end

-- A capacity lease reserves producer-side room before an irreversible source
-- obtains bytes, then atomically publishes the bytes into the Flow.
do
  local flow = Flow.new(4):label('public-space-lease')
  local lease, partial, rest, committed, got
  local st = fibers.try_run(function()
    lease = fibers.perform(flow:inlet():reserve_some_op(3, 'host-reader'))
    partial, rest = fibers.perform(flow:inlet():write_some_op('xy'))
    committed = fibers.perform(lease:commit_op('ab'))
    got = fibers.perform(flow:outlet():read_exactly_op(3))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_truthy(type(lease.capacity) == 'function', 'reservation should return a SpaceLease')
  assert_eq(lease:capacity(), 3)
  assert_eq(partial, 1, 'reservation should leave only one writable byte')
  assert_eq(rest, 'y')
  assert_eq(committed, 2)
  assert_eq(got, 'xab')
end

-- Reserved capacity blocks other producers until it is committed or released.
do
  local rt = Runtime.new()
  local flow = Flow.new(3):label('public-space-backpressure')
  local lease, written
  rt:spawn_raw(function()
    lease = rt:perform(flow:inlet():reserve_some_op(3, 'external-source'))
  end):label('reserve')
  assert_eq(rt:run().tag, 'found')

  rt:spawn_raw(function()
    written = rt:perform(flow:inlet():write_op('x'))
  end):label('writer')
  local pending = rt:run()
  assert_eq(pending.tag, 'quiescent')
  assert_nil(written, 'writer should wait while capacity is reserved')

  rt:spawn_raw(function()
    rt:perform(lease:release_op())
  end):label('release')
  drive_until(rt, function()
    return written == 1
  end, 'releasing capacity should admit the writer')
  assert_eq(written, 1)
end

-- A producer cannot publish more bytes than it reserved; the reservation
-- remains live until explicitly released or failed.
do
  local flow = Flow.new(3):label('public-space-overcommit')
  local lease, n, err, released
  local st = fibers.try_run(function()
    lease = fibers.perform(flow:inlet():reserve_some_op(2, 'external-source'))
    n, err = fibers.perform(lease:commit_op('abc'))
    released = fibers.perform(lease:release_op())
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_nil(n)
  assert_eq(err, Errors.SPACE_COMMIT_TOO_LARGE)
  assert_eq(released, true)
end

-- A losing reservation option leaves no retained capacity behind.
do
  local flow = Flow.new(3):label('public-space-losing-choice')
  local result, written, got
  local st = fibers.try_run(function()
    result =
      fibers.perform(Op.choice(
        Op.always('winner'),
        flow:inlet():reserve_some_op(3, 'loser'):map(function()
          return 'loser'
        end)
      ))
    written = fibers.perform(flow:inlet():write_op('abc'))
    got = fibers.perform(flow:outlet():read_exactly_op(3))
  end, { choice_seed = 3 }).runtime_status
  assert_eq(st.tag, 'found')
  assert_eq(result, 'winner')
  assert_eq(written, 3, 'losing reservation must release all capacity')
  assert_eq(got, 'abc')
end

-- Public data and space leases are ordinary capabilities with explicit release.
do
  local flow = Flow.new(8):label('public-flow-leases')
  local inlet, outlet = flow:inlet(), flow:outlet()
  assert_eq(Flow.Error.EOF, 'eof')
  assert_eq(Flow.Error.BROKEN_PIPE, 'broken_pipe')

  local data_lease, space_lease, data_released, space_released
  fibers.run(function()
    fibers.perform(inlet:write_op('x'))
    data_lease = fibers.perform(outlet:lease_some_op(1, 'consumer'))
    data_released = fibers.perform(data_lease:release_op())
    space_lease = fibers.perform(inlet:reserve_some_op(1, 'producer'))
    space_released = fibers.perform(space_lease:release_op())
  end)

  assert_eq(data_released, true)
  assert_eq(space_released, true)
end

-- Option records reject fields outside their documented contract.
do
  local flow = Flow.new(16):label('public-flow-options')
  local ok, err = pcall(function()
    flow:outlet():read_line_op({ unexpected = true })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('does not accept unexpected', 1, true))
end


-- Exact reads may raise the Flow's working high-water capacity without
-- consuming a prefix before the complete transactional fact is available.
do
  local flow = Flow.new(2):label('public-elastic-exact')
  local value
  local st = fibers.try_run(function(scope)
    scope:spawn(function()
      fibers.perform(flow:inlet():write_op('ab'))
      fibers.perform(flow:inlet():write_op('c'))
    end)
    value = fibers.perform(flow:outlet():read_exactly_op(3))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_eq(value, 'abc')
  assert_truthy(flow._capacity >= 3, 'exact demand should raise working capacity')
  local written, write_err = fibers.try_run(function()
    return fibers.perform(flow:inlet():write_op('abc'))
  end):unpack()
  assert_nil(written, 'elastic read growth must not widen write_op payload policy')
  assert_eq(write_err, Errors.CAPACITY)
end

-- read_all_op is one bounded EOF fact.  Its finite max drives elastic capacity
-- growth so producers can continue, while max+1 bytes prove TOO_LARGE without
-- consuming the buffered value.
do
  local flow = Flow.new(2):label('public-elastic-read-all')
  local value
  local st = fibers.try_run(function(scope)
    scope:spawn(function()
      fibers.perform(flow:inlet():write_op('ab'))
      fibers.perform(flow:inlet():write_op('cd'))
      fibers.perform(flow:inlet():close_op())
    end)
    value = fibers.perform(flow:outlet():read_all_op({ max = 8 }))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_eq(value, 'abcd')
  assert_truthy(flow._capacity >= 9, 'read_all must reserve one byte beyond max to prove oversize')
end

-- write_all_op may enlarge storage enough for one known payload, but it does
-- not grow around pre-existing backlog.  Backpressure therefore remains between
-- successive whole writes even though each admitted payload is indivisible.
do
  local flow = Flow.new(2):label('public-elastic-write-all-backpressure')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local first, blocked, drained, second, after
  local st = fibers.try_run(function()
    first = fibers.perform(inlet:write_op('ab'))
    blocked = fibers.perform(inlet:write_all_op('cdef'):or_else(Op.always('blocked')))
    drained = fibers.perform(outlet:read_exactly_op(2))
    second = fibers.perform(inlet:write_all_op('cdef'))
    after = fibers.perform(outlet:read_exactly_op(4))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_eq(first, 2)
  assert_eq(blocked, 'blocked', 'write_all must not grow around retained backlog')
  assert_eq(drained, 'ab')
  assert_eq(second, 4)
  assert_eq(after, 'cdef')
  assert_truthy(flow._capacity >= 4)
end

do
  local flow = Flow.new(2):label('public-read-all-too-large')
  local value, err, after
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_all_op('abcd'))
    fibers.perform(flow:inlet():close_op())
    value, err = fibers.perform(flow:outlet():read_all_op({ max = 3 }))
    after = fibers.perform(flow:outlet():read_exactly_op(4))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_nil(value)
  assert_eq(err, Errors.TOO_LARGE)
  assert_eq(after, 'abcd', 'read_all limit failure must not consume buffered bytes')
end

print('tests/public/test_flow.lua: ok')
