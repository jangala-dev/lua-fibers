-- tests/test_stream_mem.lua
--
-- Integration tests for:
--   - fibers.io.mem_backend
--   - fibers.io.stream
--
-- Uses the real scheduler, ops and wait/waitset machinery.
print('testing: fibers.io.mem_stream')

-- look one level up
package.path = "../src/?.lua;" .. package.path


local fibers = require 'fibers'
local stream = require 'fibers.io.stream'
local mem    = require 'fibers.io.mem_backend'


local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s (expected: %s, got: %s)", msg or "assert_eq failed",
                        tostring(expected), tostring(actual)))
  end
end

local function assert_nil(v, msg)
  if v ~= nil then
    error(string.format("%s (expected nil, got: %s)", msg or "assert_nil failed", tostring(v)))
  end
end

local function assert_true(v, msg)
  if not v then
    error(msg or "assert_true failed")
  end
end

----------------------------------------------------------------------
-- Test 1: simple one-shot write and read
----------------------------------------------------------------------

local function test_simple_read_write()
  local a_io, b_io = mem.pipe(1024)

  local a = stream.open(a_io, true, true)
  local b = stream.open(b_io, true, true)

  local payload = "hello world"

  -- Writer: write once from A to B
  fibers.spawn(function()
    local ev = a:write_string_op(payload)
    local n, err = fibers.perform(ev)
    assert_nil(err, "simple write: unexpected error")
    assert_eq(n, #payload, "simple write: wrong byte count")
  end)

  -- Reader: read exactly len(payload) bytes
  local ev = b:read_string_op{
    min    = #payload,
    max    = #payload,
    eof_ok = true,
  }

  local s, cnt, err = fibers.perform(ev)

  assert_nil(err, "simple read: unexpected error")
  assert_eq(cnt, #payload, "simple read: wrong count")
  assert_eq(s, payload, "simple read: wrong data")

  a:close()
  b:close()
end

----------------------------------------------------------------------
-- Test 2: backpressure and partial progress
--   Small buffer so writer must make progress in steps.
----------------------------------------------------------------------

local function test_backpressure_and_partial()
  -- Small buffer forces backpressure.
  local a_io, b_io = mem.pipe(4)

  local a = stream.open(a_io, true, true)
  local b = stream.open(b_io, true, true)

  local payload = "abcdef"  -- length 6, buffer capacity 4

  -- Reader: accumulate until we have the whole payload
  fibers.spawn(function()
    local collected = {}
    local total     = 0

    while total < #payload do
      -- Read at least 1 byte, at most 3 each time.
      local ev = b:read_string_op{
        min    = 1,
        max    = 3,
        eof_ok = true,
      }

      local s, cnt, err = fibers.perform(ev)
      assert_nil(err, "backpressure read: unexpected error")

      if s == nil then
        -- EOF; should not happen before we see all bytes.
        break
      end

      assert_true(cnt > 0, "backpressure read: zero-length read with data?")
      table.insert(collected, s)
      total = total + cnt
    end

    local joined = table.concat(collected)
    assert_eq(joined, payload, "backpressure read: wrong data")
  end)

  -- Writer: write the full payload as one op
  local ev = a:write_string_op(payload)
  local n, err = fibers.perform(ev)

  assert_nil(err, "backpressure write: unexpected error")
  assert_eq(n, #payload, "backpressure write: wrong byte count")

  a:close()
  b:close()
end

----------------------------------------------------------------------
-- Test 3: EOF behaviour
----------------------------------------------------------------------

local function test_eof_behaviour()
  local a_io, b_io = mem.pipe(1024)

  local a = stream.open(a_io, true, true)
  local b = stream.open(b_io, true, true)

  local payload = "end"

  -- Write then close A's half.
  fibers.spawn(function()
    local ev = a:write_string_op(payload)
    local n, err = fibers.perform(ev)
    assert_nil(err, "EOF write: unexpected error")
    assert_eq(n, #payload, "EOF write: wrong byte count")
    a:close()
  end)

  -- First read should get the payload.
  local ev1 = b:read_string_op{
    min    = #payload,
    max    = #payload,
    eof_ok = true,
  }

  local s1, cnt1, err1 = fibers.perform(ev1)
  assert_nil(err1, "EOF read(1): unexpected error")
  assert_eq(cnt1, #payload, "EOF read(1): wrong count")
  assert_eq(s1, payload, "EOF read(1): wrong data")

  -- Second read should see EOF. For read_string_op:
  --   EOF with no data → (nil, 0, err|nil)
  local ev2 = b:read_string_op{
    min    = 1,
    max    = 16,
    eof_ok = true,
  }

  local s2, cnt2, err2 = fibers.perform(ev2)
  -- EOF is not treated as an error at this layer.
  assert_nil(err2, "EOF read(2): unexpected error")
  assert_nil(s2, "EOF read(2): expected nil string at EOF")
  assert_eq(cnt2, 0, "EOF read(2): expected count == 0 at EOF")

  b:close()
end

----------------------------------------------------------------------
-- Test 4: line-style read using terminator
----------------------------------------------------------------------

local function test_line_terminator()
  local a_io, b_io = mem.pipe(1024)

  local a = stream.open(a_io, true, true)
  local b = stream.open(b_io, true, true)

  local data = "line1\nline2\n"

  fibers.spawn(function()
    local ev = a:write_string_op(data)
    local n, err = fibers.perform(ev)
    assert_nil(err, "line write: unexpected error")
    assert_eq(n, #data, "line write: wrong byte count")
    a:close()
  end)

  -- Read up to and including first "\n"
  local ev1 = b:read_string_op{
    min        = 1,
    max        = #data,
    terminator = "\n",
    eof_ok     = true,
  }

  local s1, cnt1, err1 = fibers.perform(ev1)
  assert_nil(err1, "line read(1): unexpected error")
  assert_eq(s1, "line1\n", "line read(1): wrong data")
  assert_eq(cnt1, #s1, "line read(1): wrong count")

  -- Read up to and including second "\n"
  local ev2 = b:read_string_op{
    min        = 1,
    max        = #data,
    terminator = "\n",
    eof_ok     = true,
  }

  local s2, cnt2, err2 = fibers.perform(ev2)
  assert_nil(err2, "line read(2): unexpected error")
  assert_eq(s2, "line2\n", "line read(2): wrong data")
  assert_eq(cnt2, #s2, "line read(2): wrong count")

  -- Third read should see EOF
  local ev3 = b:read_string_op{
    min        = 1,
    max        = 16,
    terminator = "\n",
    eof_ok     = true,
  }

  local s3, cnt3, err3 = fibers.perform(ev3)
  assert_nil(err3, "line read(3): unexpected error")
  assert_nil(s3, "line read(3): expected nil at EOF")
  assert_eq(cnt3, 0, "line read(3): expected count == 0 at EOF")

  b:close()
end

----------------------------------------------------------------------
-- Test 5: write after peer close
----------------------------------------------------------------------

local function test_write_after_peer_close()
  local a_io, b_io = mem.pipe(1024)

  local a = stream.open(a_io, true, true)
  local b = stream.open(b_io, true, true)

  -- Close B immediately.
  b:close()

  -- Writing from A should report "closed" from the backend.
  local ev = a:write_string_op("x")
  local _, err = fibers.perform(ev)

  -- Depending on exact semantics, n may be 0 or nil; err should be "closed".
  assert_eq(err, "closed", "write after close: expected 'closed' error")

  a:close()
end

----------------------------------------------------------------------
-- Main test runner
----------------------------------------------------------------------

local function main()
  test_simple_read_write()
  test_backpressure_and_partial()
  test_eof_behaviour()
  test_line_terminator()
  test_write_after_peer_close()
end

fibers.run(main)

print("OK\tstream + mem_backend tests passed")
