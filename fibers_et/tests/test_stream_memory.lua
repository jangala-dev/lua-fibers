package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_nil(v, msg) if v ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(v)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end
local function assert_uncommitted_status(st, msg)
  local tag = st and st.tag
  if tag ~= 'absent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local Op = fibers.Op
local Stream = fibers.Stream
local Flow = fibers.Flow

-- Primitive flow: inlet writes bytes, outlet reads bytes, handles are stable.
do
  local flow = Flow.new({ name = 'primitive-flow', capacity = 16 })
  assert_eq(flow:inlet(), flow:inlet(), 'flow inlet handle should be stable')
  assert_eq(flow:outlet(), flow:outlet(), 'flow outlet handle should be stable')
  assert_nil(flow.writer, 'primitive Flow should not expose writer alias')
  assert_nil(flow.reader, 'primitive Flow should not expose reader alias')
  local got
  local st = fibers.run(function()
    fibers.perform(flow:inlet():write_op('flow\n'))
    got = fibers.perform(flow:outlet():read_line_op())
  end)
  assert_status(st, 'found')
  assert_eq(got, 'flow')
end

-- Basic memory stream: write commits bytes to the peer's read side.
do
  local a, b = Stream.memory_pair({ name = 'basic' })
  local got
  local st = fibers.run(function()
    fibers.spawn_raw(function() fibers.perform(a:writer():write_op('hello')) end, 'writer')
    got = fibers.perform(b:reader():read_exactly_op(5))
  end)
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Losing write branches append nothing.
do
  local a, b = Stream.memory_pair({ name = 'losing-write' })
  local got
  local st = fibers.run(function()
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      a:writer():write_op('x'):map(function() return 'loser' end)
    ))
  end)
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_eq(b:reader().flow.reservoir:debug_data(), '', 'losing stream write must not append bytes')
end

-- Losing read branches consume nothing.
do
  local a, b = Stream.memory_pair({ name = 'losing-read' })
  local got, later
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('abc'))
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      b:reader():read_some_op(1):map(function() return 'loser' end)
    ))
    later = fibers.perform(b:reader():read_exactly_op(3))
  end)
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_eq(later, 'abc', 'losing stream read must not consume bytes')
end

-- Competing reads of one byte select one reader only.
do
  local a, b = Stream.memory_pair({ name = 'competing-reads' })
  local r1, r2
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() r1 = rt:perform(b:reader():read_some_op(1)) end, 'r1')
  rt:spawn_raw(function() r2 = rt:perform(b:reader():read_some_op(1)) end, 'r2')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('x')) end, 'writer')
  assert_status(rt:run(), 'found')
  rt:run() -- settle to pending if the second reader is still waiting
  local count = (r1 == 'x' and 1 or 0) + (r2 == 'x' and 1 or 0)
  assert_eq(count, 1, 'one committed byte may be consumed by one reader only')
end

-- Exact reads do not consume partial data while waiting.
do
  local a, b = Stream.memory_pair({ name = 'exact' })
  local got
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() got = rt:perform(b:reader():read_exactly_op(4)) end, 'reader')
  assert_status(rt:run(), 'pending')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('ab')) end, 'writer-ab')
  assert_status(rt:run(), 'found')
  assert_nil(got, 'exact read must still be waiting after partial data')
  assert_eq(b:reader().flow.reservoir:debug_data(), 'ab', 'partial exact read must not consume while waiting')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('cd')) end, 'writer-cd')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'abcd')
  assert_eq(b:reader().flow.reservoir:debug_data(), '')
end

-- EOF follows queued bytes after shutdown_write.
do
  local a, b = Stream.memory_pair({ name = 'eof' })
  local one, two, err
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('abc'))
    fibers.perform(a:writer():shutdown_op())
    one = fibers.perform(b:reader():read_some_op(10))
    two, err = fibers.perform(b:reader():read_some_op(10))
  end)
  assert_status(st, 'found')
  assert_eq(one, 'abc')
  assert_nil(two)
  assert_eq(err, 'eof')
end

-- Closing read side makes peer writes fail with broken_pipe.
do
  local a, b = Stream.memory_pair({ name = 'broken-pipe' })
  local n, err
  local st = fibers.run(function()
    fibers.perform(b:reader():shutdown_op())
    n, err = fibers.perform(a:writer():write_op('x'))
  end)
  assert_status(st, 'found')
  assert_nil(n)
  assert_eq(err, 'broken_pipe')
end

-- Capacity/backpressure is transactional.
do
  local a, b = Stream.memory_pair({ name = 'capacity', capacity = 3 })
  local second_done, read
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() rt:perform(a:writer():write_op('abc')) end, 'fill')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function() second_done = rt:perform(a:writer():write_op('d')) end, 'blocked-write')
  assert_status(rt:run(), 'pending')
  assert_nil(second_done, 'write should wait while capacity is full')
  rt:spawn_raw(function() read = rt:perform(b:reader():read_some_op(1)) end, 'reader')
  assert_status(rt:run(), 'found')
  assert_eq(read, 'a')
  assert_eq(second_done, 1)
  assert_eq(b:reader().flow.reservoir:debug_data(), 'bcd')
end

-- Transactional request/response: consume request, update state, append response.
do
  local a, b = Stream.memory_pair({ name = 'request-response' })
  local state = fibers.Cell.new(0, 'state')
  local response
  local function handle_one_op(stream)
    return stream:reader():read_line_op():and_then(function(line)
      return state:read_op():and_then(function(old)
        return state:write_op(old + 1):and_then(function()
          return stream:writer():write_op('reply:' .. line .. '\n')
        end):map(function() return line end)
      end)
    end)
  end
  local st = fibers.run(function()
    fibers.perform(b:writer():write_op('ping\n'))
    fibers.perform(handle_one_op(a))
    response = fibers.perform(b:reader():read_line_op())
  end)
  assert_status(st, 'found')
  assert_eq(state.value, 1)
  assert_eq(response, 'reply:ping')
end


-- Line and exact read edge cases are transactional and precise.
do
  local a, b = Stream.memory_pair({ name = 'line-cases' })
  local line, rest, tail, eof, eof_err, limited, limit_err, after_limit, exact, exact_err, partial

  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('one\nmore'))
    line = fibers.perform(b:reader():read_line_op())
    rest = fibers.perform(b:reader():read_exactly_op(4))

    fibers.perform(a:writer():write_op('tail'))
    fibers.perform(a:writer():shutdown_op())
    tail = fibers.perform(b:reader():read_line_op())
    eof, eof_err = fibers.perform(b:reader():read_some_op(1))
  end)
  assert_status(st, 'found')
  assert_eq(line, 'one')
  assert_eq(rest, 'more')
  assert_eq(tail, 'tail')
  assert_nil(eof)
  assert_eq(eof_err, 'eof')

  local c, d = Stream.memory_pair({ name = 'line-limit' })
  st = fibers.run(function()
    fibers.perform(c:writer():write_op('abcdef'))
    limited, limit_err = fibers.perform(d:reader():read_line_op({ limit = 3 }))
    after_limit = fibers.perform(d:reader():read_exactly_op(6))
  end)
  assert_status(st, 'found')
  assert_nil(limited)
  assert_eq(limit_err, 'line_too_long')
  assert_eq(after_limit, 'abcdef', 'line limit failure must not consume bytes')

  local e, f = Stream.memory_pair({ name = 'exact-eof' })
  st = fibers.run(function()
    fibers.perform(e:writer():write_op('ab'))
    fibers.perform(e:writer():shutdown_op())
    exact, exact_err, partial = fibers.perform(f:reader():read_exactly_op(4))
  end)
  assert_status(st, 'found')
  assert_nil(exact)
  assert_eq(exact_err, 'eof')
  assert_eq(partial, 'ab')
  assert_eq(f:reader().flow.reservoir:debug_data(), '', 'exact EOF consumes the returned final partial')
end

-- Region/Lifetime ownership handoff works for stream compounds.
do
  local Lifetime = fibers.Lifetime
  local a, _b = Stream.memory_pair({ name = 'handoff' })
  local from = Lifetime.new('from')
  local to = Lifetime.new('to')
  local st = fibers.run(function()
    fibers.perform(from:raw_region():admit_op(a))
    fibers.perform(a:transfer_op(from, to))
  end)
  assert_status(st, 'found')
  assert_eq(a.owner, to:raw_region())
end


-- Chunked storage preserves order without keeping one monolithic data string.
do
  local a, b = Stream.memory_pair({ name = 'chunked' })
  local big_a = string.rep('a', 9000)
  local big_b = string.rep('b', 9000)
  local first, cross, rest, st_snapshot
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op(big_a))
    fibers.perform(a:writer():write_op(big_b))
    st_snapshot = fibers.perform(b:reader().flow.reservoir:inspect_op())
    first = fibers.perform(b:reader():read_exactly_op(8999))
    cross = fibers.perform(b:reader():read_exactly_op(2))
    rest = fibers.perform(b:reader():read_exactly_op(8999))
  end)
  assert_status(st, 'found')
  assert_eq(#first, 8999)
  assert_eq(first, string.rep('a', 8999))
  assert_eq(cross, 'ab', 'reads should cross chunk boundaries in order')
  assert_eq(rest, string.rep('b', 8999))
  assert_truthy(st_snapshot.chunk_count >= 2, 'large writes should remain as multiple chunks')
  assert_eq(b:reader().flow.reservoir:debug_data(), '')
end

-- Sequential writes within one transaction preserve byte order.
do
  local a, b = Stream.memory_pair({ name = 'sequential-writes' })
  local got
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('a'):and_then(function()
      return a:writer():write_op('b')
    end))
    got = fibers.perform(b:reader():read_exactly_op(2))
  end)
  assert_status(st, 'found')
  assert_eq(got, 'ab')
end


-- Parallel writes to the same flow reservoir are deliberately conservative: they
-- conflict rather than silently inventing an ordering.
do
  local a, b = Stream.memory_pair({ name = 'parallel-write-conflict' })
  local got
  local rt = fibers.Runtime.new({ quiet_deadlock = true })
  rt:spawn_raw(function()
    got = rt:perform(Op.tensor({ a:writer():write_op('a'), a:writer():write_op('b') }))
  end, 'parallel-stream-writes')
  local st = rt:run()
  assert_uncommitted_status(st, 'parallel writes to the same stream queue should not commit')
  assert_nil(got, 'participant should not resume from conflicting parallel writes')
  assert_eq(b:reader().flow.reservoir:debug_data(), '', 'conflicting parallel stream writes leave the queue unchanged')
end


-- Long reads are observational until commit: abandoned read_line/read_all
-- attempts leave already queued bytes in the queue.
do
  local a, b = Stream.memory_pair({ name = 'long-read-abandon' })
  local line_choice, all_choice, after_line, after_all
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('partial'))
    line_choice = fibers.perform(Op.choice(
      b:reader():read_line_op({ limit = 64 }):map(function() return 'line' end),
      Op.always('timeout')
    ))
    after_line = fibers.perform(b:reader():read_exactly_op(7))

    fibers.perform(a:writer():write_op('body'))
    all_choice = fibers.perform(Op.choice(
      b:reader():read_all_op({ max = 64 }):map(function() return 'all' end),
      Op.always('timeout')
    ))
    after_all = fibers.perform(b:reader():read_exactly_op(4))
  end)
  assert_status(st, 'found')
  assert_eq(line_choice, 'timeout')
  assert_eq(after_line, 'partial', 'abandoned read_line_op must not consume queued bytes')
  assert_eq(all_choice, 'timeout')
  assert_eq(after_all, 'body', 'abandoned read_all_op must not consume queued bytes')
end

-- read_line_op can wait while the committed flow reservoir grows, then consume the
-- whole line only when the separator arrives.
do
  local a, b = Stream.memory_pair({ name = 'line-grows' })
  local line
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() line = rt:perform(b:reader():read_line_op({ limit = 16 })) end, 'line-reader')
  assert_status(rt:run(), 'pending')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('abc')) end, 'write-prefix')
  assert_status(rt:run(), 'found')
  assert_nil(line, 'read_line_op should still be waiting before separator')
  assert_eq(b:reader().flow.reservoir:debug_data(), 'abc', 'waiting read_line_op must not consume prefix')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('\nrest')) end, 'write-sep')
  assert_status(rt:run(), 'found')
  assert_eq(line, 'abc')
  assert_eq(b:reader().flow.reservoir:debug_data(), 'rest')
end

-- read_all_op is a single-commit operation: it waits for EOF and consumes only
-- when that EOF branch commits.
do
  local a, b = Stream.memory_pair({ name = 'read-all' })
  local all
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() all = rt:perform(b:reader():read_all_op({ max = 16 })) end, 'read-all')
  assert_status(rt:run(), 'pending')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('ab')) end, 'write-ab')
  assert_status(rt:run(), 'found')
  assert_nil(all, 'read_all_op should wait before EOF')
  assert_eq(b:reader().flow.reservoir:debug_data(), 'ab', 'waiting read_all_op must not consume')
  rt:spawn_raw(function() rt:perform(a:writer():write_op('cd')) end, 'write-cd')
  assert_status(rt:run(), 'found')
  assert_nil(all, 'read_all_op should still wait before EOF')
  rt:spawn_raw(function() rt:perform(a:writer():shutdown_op()) end, 'eof')
  assert_status(rt:run(), 'found')
  assert_eq(all, 'abcd')
  assert_eq(b:reader().flow.reservoir:debug_data(), '')
end

-- read_all_op enforces an explicit bound unless unlimited=true is requested;
-- exceeding the bound reports too_large without consuming bytes.
do
  local a, b = Stream.memory_pair({ name = 'read-all-limit' })
  local out, err, after
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('abcdef'))
    out, err = fibers.perform(b:reader():read_all_op({ max = 3 }))
    after = fibers.perform(b:reader():read_exactly_op(6))
  end)
  assert_status(st, 'found')
  assert_nil(out)
  assert_eq(err, 'too_large')
  assert_eq(after, 'abcdef', 'read_all limit failure must not consume bytes')

  local ok = pcall(function() b:reader():read_all_op() end)
  assert_eq(ok, false, 'read_all_op should require opts.max or opts.unlimited = true')
end

-- Unlimited read_all_op is explicit.
do
  local a, b = Stream.memory_pair({ name = 'read-all-unlimited' })
  local out
  local st = fibers.run(function()
    fibers.perform(a:writer():write_op('xyz'))
    fibers.perform(a:writer():shutdown_op())
    out = fibers.perform(b:reader():read_all_op({ unlimited = true }))
  end)
  assert_status(st, 'found')
  assert_eq(out, 'xyz')
end

-- Zero-length operations and validation are explicit.
do
  local a, b = Stream.memory_pair({ name = 'edge-validation' })
  local r0, e0, w0
  local st = fibers.run(function()
    r0 = fibers.perform(b:reader():read_some_op(0))
    e0 = fibers.perform(b:reader():read_exactly_op(0))
    w0 = fibers.perform(a:writer():write_op(''))
  end)
  assert_status(st, 'found')
  assert_eq(r0, '')
  assert_eq(e0, '')
  assert_eq(w0, 0)
  local ok = pcall(function() b:reader():read_some_op(-1) end)
  assert_eq(ok, false, 'negative read size should be rejected')
  ok = pcall(function() b:reader():read_line_op({ sep = '' }) end)
  assert_eq(ok, false, 'empty line separator should be rejected')
  ok = pcall(function() b:reader():read_line_op({ limit = -1 }) end)
  assert_eq(ok, false, 'negative line limit should be rejected')
  ok = pcall(function() b:reader():read_all_op({ max = -1 }) end)
  assert_eq(ok, false, 'negative read_all max should be rejected')
end


-- Flow internals expose byte-storage facts rather than Flow read-spec interpreters.
do
  local flow = Flow.new({ name = 'reservoir-read-facts', capacity = 32 })
  local line_fact, line_bytes, short
  local st = fibers.run(function()
    fibers.perform(flow:inlet():write_op('abc\ndef'))
    line_fact = fibers.perform(flow.reservoir:find_line_op({ sep = '\n', include_sep = false, limit = 16 }))
    line_bytes = fibers.perform(flow.reservoir:consume_op(line_fact.consume_n))
    short = fibers.perform(flow.reservoir:consume_short_op(10))
  end)
  assert_status(st, 'found')
  assert_eq(line_fact.consume_n, 4)
  assert_eq(line_fact.value_n, 3)
  assert_eq(string.sub(line_bytes, 1, line_fact.value_n), 'abc')
  assert_eq(short, 'def')
  assert_truthy(Flow.Lease, 'Lease should be the public name for retained byte ownership')
  assert_nil(Flow.Claim, 'pump Claim should not be part of the public Flow facility')
end


print('tests/test_stream_memory.lua: ok')
