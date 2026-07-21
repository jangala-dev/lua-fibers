package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Inspect = require('tests.support.flow_inspect')

local fibers = require('fibers')
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersScalar = require('fibers.scalar')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.stream')

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
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end
local function assert_uncommitted_status(st, msg)
  local tag = st and st.tag
  if tag ~= 'quiescent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local Op = FibersOp
local Stream = FibersStream
local Flow = require('fibers.flow')

-- Primitive flow: inlet writes bytes, outlet reads bytes, handles are stable.
do
  local flow = Flow.new({ name = 'primitive-flow', capacity = 16 })
  assert_eq(flow:inlet(), flow:inlet(), 'flow inlet handle should be stable')
  assert_eq(flow:outlet(), flow:outlet(), 'flow outlet handle should be stable')
  assert_nil(flow.writer, 'primitive Flow should not expose writer alias')
  assert_nil(flow.reader, 'primitive Flow should not expose reader alias')
  local got
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('flow\n'))
    got = fibers.perform(flow:outlet():read_line_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'flow')
end

-- Basic memory stream: write commits bytes to the peer's read side.
do
  local a, b = Stream.memory_pair({ name = 'basic' })
  local got
  local st = fibers.try_run(function()
    fibers.spawn(function()
      fibers.perform(a:writer():write_op('hello'))
    end, 'writer')
    got = fibers.perform(b:reader():read_exactly_op(5))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Losing write branches append nothing.
do
  local a, b = Stream.memory_pair({ name = 'losing-write' })
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      a:writer():write_op('x'):map(function()
        return 'loser'
      end)
    ))
  end, { choice_seed = 3 }).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_eq(Inspect.data(b:reader().flow), '', 'losing stream write must not append bytes')
end

-- Losing read branches consume nothing.
do
  local a, b = Stream.memory_pair({ name = 'losing-read' })
  local got, later
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('abc'))
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      b:reader():read_some_op(1):map(function()
        return 'loser'
      end)
    ))
    later = fibers.perform(b:reader():read_exactly_op(3))
  end, { choice_seed = 3 }).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_eq(later, 'abc', 'losing stream read must not consume bytes')
end

-- Competing reads of one byte select one reader only.
do
  local a, b = Stream.memory_pair({ name = 'competing-reads' })
  local r1, r2
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    r1 = rt:perform(b:reader():read_some_op(1))
  end, 'r1')
  rt:spawn_raw(function()
    r2 = rt:perform(b:reader():read_some_op(1))
  end, 'r2')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('x'))
  end, 'writer')
  assert_status(rt:run(), 'found')
  rt:run() -- settle to pending if the second reader is still waiting
  local count = (r1 == 'x' and 1 or 0) + (r2 == 'x' and 1 or 0)
  assert_eq(count, 1, 'one committed byte may be consumed by one reader only')
end

-- Exact reads do not consume partial data while waiting.
do
  local a, b = Stream.memory_pair({ name = 'exact' })
  local got
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(b:reader():read_exactly_op(4))
  end, 'reader')
  assert_status(rt:run(), 'quiescent')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('ab'))
  end, 'writer-ab')
  assert_status(rt:run(), 'found')
  assert_nil(got, 'exact read must still be waiting after partial data')
  assert_eq(Inspect.data(b:reader().flow), 'ab', 'partial exact read must not consume while waiting')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('cd'))
  end, 'writer-cd')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'abcd')
  assert_eq(Inspect.data(b:reader().flow), '')
end

-- EOF follows queued bytes after shutdown_write.
do
  local a, b = Stream.memory_pair({ name = 'eof' })
  local one, two, err
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('abc'))
    fibers.perform(a:shutdown_write_op())
    one = fibers.perform(b:reader():read_some_op(10))
    two, err = fibers.perform(b:reader():read_some_op(10))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(one, 'abc')
  assert_nil(two)
  assert_eq(err, 'eof')
end

-- Closing read side makes peer writes fail with broken_pipe.
do
  local a, b = Stream.memory_pair({ name = 'broken-pipe' })
  local n, err
  local st = fibers.try_run(function()
    fibers.perform(b:shutdown_read_op())
    n, err = fibers.perform(a:writer():write_op('x'))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(n)
  assert_eq(err, 'broken_pipe')
end

-- Capacity/backpressure is transactional.
do
  local a, b = Stream.memory_pair({ name = 'capacity', capacity = 3 })
  local second_done, read
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('abc'))
  end, 'fill')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function()
    second_done = rt:perform(a:writer():write_op('d'))
  end, 'blocked-write')
  assert_status(rt:run(), 'quiescent')
  assert_nil(second_done, 'write should wait while capacity is full')
  rt:spawn_raw(function()
    read = rt:perform(b:reader():read_some_op(1))
  end, 'reader')
  assert_status(rt:run(), 'found')
  assert_eq(read, 'a')
  assert_eq(second_done, 1)
  assert_eq(Inspect.data(b:reader().flow), 'bcd')
end

-- Transactional request/response: consume request, update state, append response.
do
  local a, b = Stream.memory_pair({ name = 'request-response' })
  local state = FibersScalar.new(0, 'state')
  local response
  local function handle_one_op(stream)
    return stream:reader():read_line_op():and_then(function(line)
      return state:read_op():and_then(function(old)
        return state
          :write_op(old + 1)
          :and_then(function()
            return stream:writer():write_op('reply:' .. line .. '\n')
          end)
          :map(function()
            return line
          end)
      end)
    end)
  end
  local st = fibers.try_run(function()
    fibers.perform(b:writer():write_op('ping\n'))
    fibers.perform(handle_one_op(a))
    response = fibers.perform(b:reader():read_line_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(state.value, 1)
  assert_eq(response, 'reply:ping')
end

-- Line and exact read edge cases are transactional and precise.
do
  local a, b = Stream.memory_pair({ name = 'line-cases' })
  local line, rest, tail, eof, eof_err, limited, limit_err, after_limit, exact, exact_err, partial

  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('one\nmore'))
    line = fibers.perform(b:reader():read_line_op())
    rest = fibers.perform(b:reader():read_exactly_op(4))

    fibers.perform(a:writer():write_op('tail'))
    fibers.perform(a:shutdown_write_op())
    tail = fibers.perform(b:reader():read_line_op())
    eof, eof_err = fibers.perform(b:reader():read_some_op(1))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(line, 'one')
  assert_eq(rest, 'more')
  assert_eq(tail, 'tail')
  assert_nil(eof)
  assert_eq(eof_err, 'eof')

  local c, d = Stream.memory_pair({ name = 'line-limit' })
  st = fibers.try_run(function()
    fibers.perform(c:writer():write_op('abcdef'))
    limited, limit_err = fibers.perform(d:reader():read_line_op({ max = 3 }))
    after_limit = fibers.perform(d:reader():read_exactly_op(6))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(limited)
  assert_eq(limit_err, 'line_too_long')
  assert_eq(after_limit, 'abcdef', 'line limit failure must not consume bytes')

  local e, f = Stream.memory_pair({ name = 'exact-eof' })
  st = fibers.try_run(function()
    fibers.perform(e:writer():write_op('ab'))
    fibers.perform(e:shutdown_write_op())
    exact, exact_err, partial = fibers.perform(f:reader():read_exactly_op(4))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(exact)
  assert_eq(exact_err, 'eof')
  assert_eq(partial, 'ab')
  assert_eq(Inspect.data(f:reader().flow), '', 'exact EOF consumes the returned final partial')
end

-- Region/Scope ownership movement works for stream compounds.
do
  local Scope = FibersScope
  local a, _b = Stream.memory_pair({ name = 'movement' })
  local from = Scope.new('from')
  local to = Scope.new('to')
  local st = fibers.try_run(function()
    fibers.perform(from:raw_region():admit_op(a))
    fibers.perform(from:raw_region():move_op(a, to:raw_region()))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(a.owner, to:raw_region())
end

-- Chunked storage preserves order without keeping one monolithic data string.
do
  local a, b = Stream.memory_pair({ name = 'chunked' })
  local big_a = string.rep('a', 9000)
  local big_b = string.rep('b', 9000)
  local first, cross, rest, st_snapshot
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op(big_a))
    fibers.perform(a:writer():write_op(big_b))
    st_snapshot = fibers.perform(b:reader().flow:inspect_op())
    first = fibers.perform(b:reader():read_exactly_op(8999))
    cross = fibers.perform(b:reader():read_exactly_op(2))
    rest = fibers.perform(b:reader():read_exactly_op(8999))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(#first, 8999)
  assert_eq(first, string.rep('a', 8999))
  assert_eq(cross, 'ab', 'reads should cross chunk boundaries in order')
  assert_eq(rest, string.rep('b', 8999))
  assert_truthy(st_snapshot.chunk_count >= 2, 'large writes should remain as multiple chunks')
  assert_eq(Inspect.data(b:reader().flow), '')
end

-- Sequential writes within one transaction preserve byte order.
do
  local a, b = Stream.memory_pair({ name = 'sequential-writes' })
  local got
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('a'):and_then(function()
      return a:writer():write_op('b')
    end))
    got = fibers.perform(b:reader():read_exactly_op(2))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'ab')
end

-- Parallel writes to a scalar-state-machine flow serialise in transition order.
do
  local a, b = Stream.memory_pair({ name = 'parallel-write-serial' })
  local got
  local rt = FibersRuntime.new({ quiet_deadlock = true })
  rt:spawn_raw(function()
    got = rt:perform(Op.tensor({ a:writer():write_op('a'), a:writer():write_op('b') }))
  end, 'parallel-stream-writes')
  local st = rt:run()
  assert_status(st, 'found')
  assert_truthy(got, 'participant should resume from serialised parallel writes')
  assert_eq(
    Inspect.data(b:reader().flow),
    'ab',
    'parallel stream writes are ordered by scalar transition order'
  )
end

-- Long reads are observational until commit: abandoned read_line/read_all
-- attempts leave already queued bytes in the queue.
do
  local a, b = Stream.memory_pair({ name = 'long-read-abandon' })
  local line_choice, all_choice, after_line, after_all
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('partial'))
    line_choice = fibers.perform(b:reader()
      :read_line_op({ max = 64 })
      :map(function()
        return 'line'
      end)
      :or_else(Op.always('timeout')))
    after_line = fibers.perform(b:reader():read_exactly_op(7))

    fibers.perform(a:writer():write_op('body'))
    all_choice = fibers.perform(b:reader()
      :read_all_op({ max = 64 })
      :map(function()
        return 'all'
      end)
      :or_else(Op.always('timeout')))
    after_all = fibers.perform(b:reader():read_exactly_op(4))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(line_choice, 'timeout')
  assert_eq(after_line, 'partial', 'abandoned read_line_op must not consume queued bytes')
  assert_eq(all_choice, 'timeout')
  assert_eq(after_all, 'body', 'abandoned read_all_op must not consume queued bytes')
end

-- read_line_op can wait while the committed flow buffer grows, then consume the
-- whole line only when the separator arrives.
do
  local a, b = Stream.memory_pair({ name = 'line-grows' })
  local line
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    line = rt:perform(b:reader():read_line_op({ max = 16 }))
  end, 'line-reader')
  assert_status(rt:run(), 'quiescent')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('abc'))
  end, 'write-prefix')
  assert_status(rt:run(), 'found')
  assert_nil(line, 'read_line_op should still be waiting before separator')
  assert_eq(Inspect.data(b:reader().flow), 'abc', 'waiting read_line_op must not consume prefix')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('\nrest'))
  end, 'write-sep')
  assert_status(rt:run(), 'found')
  assert_eq(line, 'abc')
  assert_eq(Inspect.data(b:reader().flow), 'rest')
end

-- read_all_op is a single-commit option: it waits for EOF and consumes only
-- when that EOF branch commits.
do
  local a, b = Stream.memory_pair({ name = 'read-all' })
  local all
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    all = rt:perform(b:reader():read_all_op({ max = 16 }))
  end, 'read-all')
  assert_status(rt:run(), 'quiescent')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('ab'))
  end, 'write-ab')
  assert_status(rt:run(), 'found')
  assert_nil(all, 'read_all_op should wait before EOF')
  assert_eq(Inspect.data(b:reader().flow), 'ab', 'waiting read_all_op must not consume')
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('cd'))
  end, 'write-cd')
  assert_status(rt:run(), 'found')
  assert_nil(all, 'read_all_op should still wait before EOF')
  rt:spawn_raw(function()
    rt:perform(a:shutdown_write_op())
  end, 'eof')
  assert_status(rt:run(), 'found')
  assert_eq(all, 'abcd')
  assert_eq(Inspect.data(b:reader().flow), '')
end

-- read_all_op enforces an explicit bound unless unlimited=true is requested;
-- exceeding the bound reports too_large without consuming bytes.
do
  local a, b = Stream.memory_pair({ name = 'read-all-limit' })
  local out, err, after
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('abcdef'))
    out, err = fibers.perform(b:reader():read_all_op({ max = 3 }))
    after = fibers.perform(b:reader():read_exactly_op(6))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(out)
  assert_eq(err, 'too_large')
  assert_eq(after, 'abcdef', 'read_all limit failure must not consume bytes')

  local ok = pcall(function()
    b:reader():read_all_op()
  end)
  assert_eq(ok, false, 'read_all_op should require opts.max or opts.unlimited = true')
end

-- Unlimited read_all_op is explicit.
do
  local a, b = Stream.memory_pair({ name = 'read-all-unlimited' })
  local out
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('xyz'))
    fibers.perform(a:shutdown_write_op())
    out = fibers.perform(b:reader():read_all_op({ max = math.huge }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(out, 'xyz')
end

-- Zero-length options and validation are explicit.
do
  local a, b = Stream.memory_pair({ name = 'edge-validation' })
  local r0, e0, w0
  local st = fibers.try_run(function()
    r0 = fibers.perform(b:reader():read_some_op(0))
    e0 = fibers.perform(b:reader():read_exactly_op(0))
    w0 = fibers.perform(a:writer():write_op(''))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(r0, '')
  assert_eq(e0, '')
  assert_eq(w0, 0)
  local ok = pcall(function()
    b:reader():read_some_op(-1)
  end)
  assert_eq(ok, false, 'negative read size should be rejected')
  ok = pcall(function()
    b:reader():read_line_op({ terminator = '' })
  end)
  assert_eq(ok, false, 'empty line separator should be rejected')
  ok = pcall(function()
    b:reader():read_line_op({ max = -1 })
  end)
  assert_eq(ok, false, 'negative line limit should be rejected')
  ok = pcall(function()
    b:reader():read_all_op({ max = -1 })
  end)
  assert_eq(ok, false, 'negative read_all max should be rejected')
end

-- Flow exposes delimiter helpers above the byte-storage machine.
do
  local flow = Flow.new({ name = 'flow-derived-read-facts', capacity = 32 })
  local line, tail
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abc\ndef'))
    line = fibers.perform(flow:outlet():read_until_op('\n'))
    tail = fibers.perform(flow:outlet():read_exactly_op(3))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(line, 'abc')
  assert_eq(tail, 'def')
  assert_nil(flow.reservoir, 'Flow should not expose an internal reservoir object')
  assert_nil(Flow.Lease, 'lease implementation classes are not public')
  assert_nil(Flow.SpaceLease, 'space lease implementation classes are not public')
  assert_nil(Flow.Reservoir, 'reservoir implementation is not public')
  assert_nil(Flow.Errors, 'internal error vocabulary is not public')
  assert_eq(Flow.Error.EOF, 'eof')
  assert_nil(Flow.Claim, 'the retired Claim type should not be part of the public Flow facility')
end

print('tests/test_stream_memory.lua: ok')

-- Migration helpers retain option semantics.
do
  fibers.run(function()
    local a, b = Stream.memory_pair({ capacity = 64 })
    fibers.perform(a:write_op('hello', ' ', 'world\n'))
    local line = fibers.perform(b:read_op('*l'))
    assert_eq(line, 'hello world')
  end)
end
