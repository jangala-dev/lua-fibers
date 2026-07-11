package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Op = fibers.Op
local Flow = require('fibers.flow')
local Errors = require('fibers.flow.errors')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_nil(v, msg) if v ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(v)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- peek observes without consuming, even when the selected world commits.
do
  local flow = Flow.new({ name = 'peek-flow', capacity = 16 })
  local p, later
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    p = fibers.perform(flow:outlet():peek_op(3))
    later = fibers.perform(flow:outlet():read_exactly_op(6))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(p, 'abc')
  assert_eq(later, 'abcdef')
end

-- read_until excludes the delimiter; read_including includes it. Both consume
-- through the delimiter only when the selected world commits.
do
  local flow = Flow.new({ name = 'until-flow', capacity = 32 })
  local before, including, tail
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abc--def--tail'))
    before = fibers.perform(flow:outlet():read_until_op('--'))
    including = fibers.perform(flow:outlet():read_including_op('--'))
    tail = fibers.perform(flow:outlet():read_exactly_op(4))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(before, 'abc')
  assert_eq(including, 'def--')
  assert_eq(tail, 'tail')
end

-- read_until default terminal partial policy reports eof and the partial.
do
  local flow = Flow.new({ name = 'until-partial-flow', capacity = 16 })
  local got, err, partial, after_err
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('unterminated'))
    fibers.perform(flow:inlet():shutdown_op())
    got, err, partial = fibers.perform(flow:outlet():read_until_op('\n'))
    local again
    again, after_err = fibers.perform(flow:outlet():read_some_op(1))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(got)
  assert_eq(err, 'eof')
  assert_eq(partial, 'unterminated')
  assert_eq(after_err, 'eof')
end

-- read_line is a small consumer of read_until with partial return semantics.
do
  local flow = Flow.new({ name = 'line-derived-flow', capacity = 16 })
  local line, eof, eof_err
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('tail'))
    fibers.perform(flow:inlet():shutdown_op())
    line = fibers.perform(flow:outlet():read_line_op())
    eof, eof_err = fibers.perform(flow:outlet():read_line_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(line, 'tail')
  assert_nil(eof)
  assert_eq(eof_err, 'eof')
end

-- drop is derived from exact read and does not return bytes.
do
  local flow = Flow.new({ name = 'drop-flow', capacity = 16 })
  local dropped, tail
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    dropped = fibers.perform(flow:outlet():drop_op(2))
    tail = fibers.perform(flow:outlet():read_exactly_op(4))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(dropped, 2)
  assert_eq(tail, 'cdef')
end

-- splice_to is algebraically derived: losing splice branches leave both flows
-- unchanged, while selected splice moves bytes as one committed world.
do
  local src = Flow.new({ name = 'splice-src', capacity = 16 })
  local dst = Flow.new({ name = 'splice-dst', capacity = 16 })
  local choice, moved, src_left, dst_got
  local st = fibers.try_run(function()
    fibers.perform(src:inlet():write_op('abcdef'))
    choice = fibers.perform(Op.choice(
      Op.always('winner'),
      src:outlet():splice_to(dst:inlet(), 3):map(function() return 'loser' end)
    ))
    moved = fibers.perform(src:outlet():splice_to(dst:inlet(), 3))
    src_left = fibers.perform(src:outlet():read_exactly_op(3))
    dst_got = fibers.perform(dst:outlet():read_exactly_op(3))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(choice, 'winner')
  assert_eq(moved, 3)
  assert_eq(src_left, 'def')
  assert_eq(dst_got, 'abc')
end


-- splice_to must not consume source bytes when the destination cannot accept
-- the bytes.  The derived law is peek -> write -> drop, not read -> write.
do
  local src = Flow.new({ name = 'splice-too-large-src', capacity = 16 })
  local dst = Flow.new({ name = 'splice-too-large-dst', capacity = 2 })
  local moved, err, src_left, dst_snap
  local st = fibers.try_run(function()
    fibers.perform(src:inlet():write_op('abc'))
    moved, err = fibers.perform(src:outlet():splice_to(dst:inlet(), 3))
    src_left = fibers.perform(src:outlet():read_exactly_op(3))
    dst_snap = fibers.perform(dst:inspect_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(moved)
  assert_eq(err, Errors.TOO_LARGE)
  assert_eq(src_left, 'abc', 'failed destination write must not consume source')
  assert_eq(dst_snap.queued_length, 0, 'failed splice must not append destination bytes')
end

-- Destination closure is another write-side failure; it must also leave the
-- source untouched.
do
  local src = Flow.new({ name = 'splice-closed-src', capacity = 16 })
  local dst = Flow.new({ name = 'splice-closed-dst', capacity = 16 })
  local moved, err, src_left, dst_snap
  local st = fibers.try_run(function()
    fibers.perform(src:inlet():write_op('abc'))
    fibers.perform(dst:inlet():shutdown_op())
    moved, err = fibers.perform(src:outlet():splice_to(dst:inlet(), 3))
    src_left = fibers.perform(src:outlet():read_exactly_op(3))
    dst_snap = fibers.perform(dst:inspect_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(moved)
  assert_eq(err, Errors.CLOSED)
  assert_eq(src_left, 'abc', 'closed destination must not consume source')
  assert_eq(dst_snap.queued_length, 0, 'closed destination must not receive bytes')
end

-- A multi-byte delimiter prefix at the payload limit is not too large yet: it
-- may still become the terminator.  A non-prefix byte past the limit is too
-- large and does not consume.
do
  local flow = Flow.new({ name = 'until-multibyte-prefix-flow', capacity = 16 })
  local got, err
  local rt = fibers.Runtime.new()
  rt:spawn_raw(function() rt:perform(flow:inlet():write_op('abc\r')) end, 'seed')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function() got, err = rt:perform(flow:outlet():read_until_op('\r\n', { limit = 3 })) end, 'reader')
  local st = rt:run()
  assert_status(st, 'quiescent', 'terminator prefix at limit should have no external wake interest')
  assert_nil(got)
  assert_nil(err)
  rt:spawn_raw(function() rt:perform(flow:inlet():write_op('\n')) end, 'finish')
  st = rt:run()
  if got == nil then st = rt:run() end
  assert_eq(got, 'abc')
  assert_nil(err)
end

do
  local flow = Flow.new({ name = 'until-multibyte-too-large-flow', capacity = 16 })
  local got, err, left
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcd'))
    got, err = fibers.perform(flow:outlet():read_until_op('\r\n', { limit = 3 }))
    left = fibers.perform(flow:outlet():read_exactly_op(4))
  end).runtime_status
  assert_status(st, 'found')
  assert_nil(got)
  assert_eq(err, Errors.TOO_LARGE)
  assert_eq(left, 'abcd', 'too-large delimiter failure should not consume bytes')
end

-- append and drain are flow-language aliases for write and flush.
do
  local flow = Flow.new({ name = 'aliases-flow', capacity = 16 })
  local n, drained, got
  local st = fibers.try_run(function()
    n = fibers.perform(flow:inlet():append_op('xy'))
    got = fibers.perform(flow:outlet():read_exactly_op(2))
    drained = fibers.perform(flow:inlet():drain_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(n, 2)
  assert_eq(got, 'xy')
  assert_eq(drained, true)
end

print('tests/test_flow_helpers.lua: ok')
