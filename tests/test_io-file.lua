-- tests/test_stream_mem.lua
--
-- Integration tests for:
--   - fibers.io.file
--   - fibers.io.fd_backend
--   - fibers.io.stream
--
-- Uses the real scheduler, ops and wait/waitset machinery.
print('testing: fibers.io.file')

-- look one level up
package.path = "../src/?.lua;" .. package.path

-- Assertion-based checks for fibers.io.file and stream I/O.
-- Exercises:
--   - tmpfile round-trip
--   - pipe round-trip + EOF behaviour
--   - use-after-close errors on streams
--   - cancellation of a scope while an IO op is blocked
--   - line-based reads via read/read_op
--   - read_all and read_exactly helpers
--   - numeric read formats, including n == 0
--   - write_op/write with multiple arguments
--   - merge_lines_op across multiple streams
--   - setvbuf, filename, rename, nonblock/block, is_stream

local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local file_mod  = require 'fibers.io.file'
local scope_mod = require 'fibers.scope'
local stream_mod = require 'fibers.io.stream'

local perform = fibers.perform

math.randomseed(os.time())

----------------------------------------------------------------------
-- 1. tmpfile round-trip
----------------------------------------------------------------------

local function test_tmpfile_roundtrip()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  local msg = "hello, tmpfile"
  local n, werr = perform(f:write_string_op(msg))
  assert(n == #msg, "write_string_op wrote " .. tostring(n) .. " bytes, expected " .. #msg)
  assert(werr == nil, "write_string_op returned error: " .. tostring(werr))

  -- Rewind to the start.
  local pos, serr = f:seek("set", 0)
  assert(pos ~= nil, "seek failed: " .. tostring(serr))

  local s, cnt, rerr = perform(f:read_string_op{
    min    = #msg,
    max    = #msg,
    eof_ok = true,
  })

  assert(rerr == nil, "read_string_op returned error: " .. tostring(rerr))
  assert(cnt == #msg, "read_string_op read " .. tostring(cnt) .. " bytes, expected " .. #msg)
  assert(s == msg, ("read_string_op returned %q, expected %q"):format(tostring(s), tostring(msg)))

  local ok, cerr = f:close()
  assert(ok, "tmpfile:close() failed: " .. tostring(cerr))
end

----------------------------------------------------------------------
-- 2. pipe round-trip + EOF semantics
----------------------------------------------------------------------

local function test_pipe_roundtrip_and_eof()
  local r, w = file_mod.pipe()
  assert(r and w, "pipe() did not return read and write streams")

  local msg = "pipe-test"
  local n, werr = perform(w:write_string_op(msg))
  assert(n == #msg, "pipe write_string_op wrote " .. tostring(n) .. " bytes, expected " .. #msg)
  assert(werr == nil, "pipe write_string_op returned error: " .. tostring(werr))

  local s, cnt, rerr = perform(r:read_string_op{
    min    = #msg,
    max    = #msg,
    eof_ok = true,
  })

  assert(rerr == nil, "pipe read_string_op returned error: " .. tostring(rerr))
  assert(cnt == #msg, "pipe read_string_op read " .. tostring(cnt) .. " bytes, expected " .. #msg)
  assert(s == msg, ("pipe read_string_op returned %q, expected %q"):format(tostring(s), tostring(msg)))

  -- Close the write end and ensure the reader sees EOF.
  local okw, errw = w:close()
  assert(okw, "pipe write stream close failed: " .. tostring(errw))

  local s2, cnt2, rerr2 = perform(r:read_string_op{
    min    = 1,
    eof_ok = true,
  })

  -- At EOF, read_string_op should return (nil, 0, nil).
  assert(s2 == nil, "expected nil at EOF, got " .. tostring(s2))
  assert(cnt2 == 0, "expected byte count 0 at EOF, got " .. tostring(cnt2))
  assert(rerr2 == nil, "expected no error at EOF, got " .. tostring(rerr2))

  local okr, errr = r:close()
  assert(okr, "pipe read stream close failed: " .. tostring(errr))
end

----------------------------------------------------------------------
-- 3. use-after-close error paths
----------------------------------------------------------------------

local function test_closed_stream_errors()
  -- Use a fresh pipe for write-after-close.
  local r1, w1 = file_mod.pipe()
  assert(r1 and w1, "pipe() did not return read and write streams")

  local okw1, errw1 = w1:close()
  assert(okw1, "write stream close failed: " .. tostring(errw1))

  -- Writing via an already-closed Stream should raise "stream is not writable".
  local ok, err = pcall(function()
    return perform(w1:write_string_op("abc"))
  end)
  assert(not ok, "expected write after close to fail with an assertion")
  assert(tostring(err):match("stream is not writable"),
         "unexpected write-after-close error: " .. tostring(err))

  -- Use a fresh pipe for read-after-close.
  local r2, w2 = file_mod.pipe()
  assert(r2 and w2, "pipe() did not return read and write streams")

  local okr2, errr2 = r2:close()
  assert(okr2, "read stream close failed: " .. tostring(errr2))

  -- Reading via an already-closed Stream should raise "stream is not readable".
  ok, err = pcall(function()
    return perform(r2:read_string_op{
      min    = 1,
      eof_ok = false,
    })
  end)
  assert(not ok, "expected read after close to fail with an assertion")
  assert(tostring(err):match("stream is not readable"),
         "unexpected read-after-close error: " .. tostring(err))

  -- Clean up the remaining write end.
  local okw2, errw2 = w2:close()
  assert(okw2, "second write stream close failed: " .. tostring(errw2))
end

----------------------------------------------------------------------
-- 4. Cancellation + IO: a child scope with a blocked read
----------------------------------------------------------------------

local function test_cancellation_cancels_blocked_read()
  -- Use scope.run to create a nested child scope whose cancellation
  -- does not affect the top-level scope used by fibers.run.
  local status, err = scope_mod.run(function(child)
    local r, w = file_mod.pipe()
    assert(r and w, "pipe() did not return read and write streams")

    -- Spawn a canceller fiber under the child scope.
    child:spawn(function(s)
      -- Give the reader time to block.
      perform(sleep.sleep_op(0.01))
      s:cancel("test cancellation")
    end)

    -- Perform a read that will block (nothing is written).
    local v1, v2, v3 = perform(r:read_string_op{
      min    = 1,
      eof_ok = true,
    })

    -- Under Scope:run_ev semantics, cancellation races the IO op.
    -- When cancellation wins, the cancel_op returns:
    --   false, reason, nil
    assert(v1 == false,
           "expected first result false from cancelled op, got " .. tostring(v1))
    assert(v2 == "test cancellation",
           "expected cancellation reason 'test cancellation', got " .. tostring(v2))
    assert(v3 == nil,
           "expected third result nil from cancel_op, got " .. tostring(v3))

    -- Close streams to avoid leaks; at this point cancellation has
    -- already been signalled.
    local okr, errr = r:close()
    local okw, errw = w:close()
    assert(okr, "reader close failed after cancellation: " .. tostring(errr))
    assert(okw, "writer close failed after cancellation: " .. tostring(errw))
  end)

  if status == "failed" then
    error(err)
  end

  -- From the outer point of view, the nested scope should report as cancelled.
  assert(status == "cancelled",
         "expected child scope status 'cancelled', got " .. tostring(status))
  assert(err == "test cancellation",
         "unexpected child scope cancellation error: " .. tostring(err))
end

----------------------------------------------------------------------
-- 5. Line-based reads via Stream:read / read_op
----------------------------------------------------------------------

local function test_read_line_variants()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  local content = "line1\nline2\n"
  local n, werr = f:write(content)
  assert(werr == nil, "write failed in test_read_line_variants: " .. tostring(werr))
  assert(n == #content, "write wrote " .. tostring(n) .. " bytes, expected " .. #content)

  local pos, serr = f:seek("set", 0)
  assert(pos == 0, "seek to start failed: " .. tostring(serr))

  -- Default / "*l": line without terminator.
  local l1, e1 = f:read()  -- equivalent to "*l"
  assert(e1 == nil, "read('*l') returned error: " .. tostring(e1))
  assert(l1 == "line1", "read('*l') returned " .. tostring(l1) .. ", expected 'line1'")

  -- "*L": line with terminator.
  local l2, e2 = f:read("*L")
  assert(e2 == nil, "read('*L') returned error: " .. tostring(e2))
  assert(l2 == "line2\n", "read('*L') returned " .. tostring(l2) .. ", expected 'line2\\n'")

  -- EOF: another line should give nil, nil.
  local l3, e3 = f:read("*l")
  assert(l3 == nil, "expected nil at EOF from read('*l'), got " .. tostring(l3))
  assert(e3 == nil, "expected nil error at EOF from read('*l'), got " .. tostring(e3))

  local ok, cerr = f:close()
  assert(ok, "tmpfile close failed in test_read_line_variants: " .. tostring(cerr))
end

----------------------------------------------------------------------
-- 6. read_all, read_exactly and numeric read formats
----------------------------------------------------------------------

local function test_read_all_and_exactly()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  local content = "abc123"
  local n, werr = f:write(content)
  assert(werr == nil, "write failed in test_read_all_and_exactly: " .. tostring(werr))
  assert(n == #content, "write wrote " .. tostring(n) .. " bytes, expected " .. #content)

  local pos, serr = f:seek("set", 0)
  assert(pos == 0, "seek to start failed: " .. tostring(serr))

  -- read_all should return the whole string.
  local all, eall = f:read_all()
  assert(eall == nil, "read_all returned error: " .. tostring(eall))
  assert(all == content, "read_all returned " .. tostring(all) .. ", expected " .. tostring(content))

  -- Rewind and exercise read_exactly.
  pos, serr = f:seek("set", 0)
  assert(pos == 0, "seek to start failed (2): " .. tostring(serr))

  local s1, e1 = f:read_exactly(3)
  assert(e1 == nil, "read_exactly(3) returned error: " .. tostring(e1))
  assert(s1 == "abc", "read_exactly(3) returned " .. tostring(s1) .. ", expected 'abc'")

  local s2, e2 = f:read_exactly(3)
  assert(e2 == nil, "read_exactly(3) second returned error: " .. tostring(e2))
  assert(s2 == "123", "read_exactly(3) second returned " .. tostring(s2) .. ", expected '123'")

  -- EOF: attempting to read beyond end should give "short read".
  local s3, e3 = f:read_exactly(1)
  assert(s3 == nil, "expected nil from read_exactly beyond EOF, got " .. tostring(s3))
  assert(e3 == "short read", "expected 'short read' error, got " .. tostring(e3))

  local ok, cerr = f:close()
  assert(ok, "tmpfile close failed in test_read_all_and_exactly: " .. tostring(cerr))
end

local function test_read_numeric_formats()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  local content = "xyz"
  local n, werr = f:write(content)
  assert(werr == nil, "write failed in test_read_numeric_formats: " .. tostring(werr))
  assert(n == #content, "write wrote " .. tostring(n) .. " bytes, expected " .. #content)

  local pos, serr = f:seek("set", 0)
  assert(pos == 0, "seek to start failed: " .. tostring(serr))

  -- n == 0: should return "" immediately.
  local s0, e0 = f:read(0)
  assert(e0 == nil, "read(0) returned error: " .. tostring(e0))
  assert(s0 == "", "read(0) returned " .. tostring(s0) .. ", expected empty string")

  -- n > 0: read up to n bytes; EOF semantics.
  local s1, e1 = f:read(1)
  assert(e1 == nil, "read(1) returned error: " .. tostring(e1))
  assert(s1 == "x", "read(1) returned " .. tostring(s1) .. ", expected 'x'")

  local s2, e2 = f:read(10) -- remaining two bytes
  assert(e2 == nil, "read(10) returned error: " .. tostring(e2))
  assert(s2 == "yz", "read(10) returned " .. tostring(s2) .. ", expected 'yz'")

  local s3, e3 = f:read(1) -- EOF now
  assert(s3 == nil, "expected nil at EOF from read(1), got " .. tostring(s3))
  assert(e3 == nil, "expected nil error at EOF from read(1), got " .. tostring(e3))

  local ok, cerr = f:close()
  assert(ok, "tmpfile close failed in test_read_numeric_formats: " .. tostring(cerr))
end

----------------------------------------------------------------------
-- 7. write_op / write wrappers
----------------------------------------------------------------------

local function test_write_variants()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  -- Zero-argument write should succeed and write nothing.
  local n0, e0 = f:write()
  assert(e0 == nil, "zero-arg write returned error: " .. tostring(e0))
  assert(n0 == 0, "zero-arg write returned " .. tostring(n0) .. ", expected 0")

  -- Multi-argument write should tostring each argument.
  local _, werr = f:write("foo", 123, true)
  assert(werr == nil, "write returned error: " .. tostring(werr))

  local pos, serr = f:seek("set", 0)
  assert(pos == 0, "seek to start failed: " .. tostring(serr))

  local s, e = f:read_all()
  assert(e == nil, "read_all returned error after write: " .. tostring(e))
  assert(s == "foo123true",
         "read_all returned " .. tostring(s) .. ", expected 'foo123true'")

  local ok, cerr = f:close()
  assert(ok, "tmpfile close failed in test_write_variants: " .. tostring(cerr))
end

----------------------------------------------------------------------
-- 8. merge_lines_op across multiple streams
----------------------------------------------------------------------

local function test_merge_lines_op()
  local r1, w1 = file_mod.pipe()
  local r2, w2 = file_mod.pipe()
  assert(r1 and w1 and r2 and w2, "pipe() did not return streams")

  local named = {
    a = r1,
    b = r2,
  }

  -- Spawn writers under the top-level scope; ignore the scope argument.
  fibers.spawn(function(_, w)
    local _, err = w:write("line-a\n")
    assert(err == nil, "writer a write error: " .. tostring(err))
    local ok, cerr = w:close()
    assert(ok, "writer a close error: " .. tostring(cerr))
  end, w1)

  fibers.spawn(function(_, w)
    local _, err = w:write("line-b\n")
    assert(err == nil, "writer b write error: " .. tostring(err))
    local ok, cerr = w:close()
    assert(ok, "writer b close error: " .. tostring(cerr))
  end, w2)

  local op = stream_mod.merge_lines_op(named, { terminator = "\n" })
  local name, line, err = perform(op)

  assert(err == nil, "merge_lines_op returned error: " .. tostring(err))
  assert(name == "a" or name == "b",
         "merge_lines_op returned unexpected name: " .. tostring(name))

  if name == "a" then
    assert(line == "line-a", "expected 'line-a' from arm 'a', got " .. tostring(line))
  else
    assert(line == "line-b", "expected 'line-b' from arm 'b', got " .. tostring(line))
  end

  -- Close the remaining reader.
  local ok1, cerr1 = r1:close()
  local ok2, cerr2 = r2:close()
  assert(ok1, "reader r1 close failed: " .. tostring(cerr1))
  assert(ok2, "reader r2 close failed: " .. tostring(cerr2))
end

----------------------------------------------------------------------
-- 9. setvbuf, filename, rename, nonblock/block, is_stream
----------------------------------------------------------------------

local function test_stream_properties_and_rename()
  local f, err = file_mod.tmpfile()
  assert(f, "tmpfile() failed: " .. tostring(err))

  -- is_stream
  assert(stream_mod.is_stream(f), "is_stream did not recognise a Stream")
  assert(not stream_mod.is_stream(123), "is_stream misclassified a number")

  -- filename should be non-nil for tmpfile
  local fname = f:filename()
  assert(fname ~= nil, "tmpfile:filename() returned nil")

  -- setvbuf toggles line_buffering flag
  assert(f.line_buffering == false, "expected line_buffering default false")
  f:setvbuf("line")
  assert(f.line_buffering == true, "setvbuf('line') did not set line_buffering")
  f:setvbuf("no")
  assert(f.line_buffering == false, "setvbuf('no') did not clear line_buffering")
  f:setvbuf("full")
  assert(f.line_buffering == false, "setvbuf('full') did not clear line_buffering")

  -- nonblock/block should be safe no-ops for fd-backed streams.
  f:nonblock()
  f:block()

  -- Rename the tmpfile to a stable name and ensure it persists after close.
  local newname = fname .. ".renamed"
  local rok, rerr = f:rename(newname)
  assert(rok, "rename failed: " .. tostring(rerr))
  assert(f:filename() == newname,
         "filename after rename was " .. tostring(f:filename()) .. ", expected " .. tostring(newname))

  local ok, cerr = f:close()
  assert(ok, "tmpfile close after rename failed: " .. tostring(cerr))

  -- The renamed file should now exist and be openable via file_mod.open.
  local f2, oerr = file_mod.open(newname, "r")
  assert(f2, "expected to reopen renamed file, got error: " .. tostring(oerr))

  local _, e = f2:read_all()
  assert(e == nil, "read_all from reopened file returned error: " .. tostring(e))
  -- Content is not prescribed here; just ensure read_all works and the stream is valid.

  local ok2, cerr2 = f2:close()
  assert(ok2, "reopened stream close failed: " .. tostring(cerr2))

  -- Clean up the renamed file to avoid littering.
  os.remove(newname)
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function main()
  test_tmpfile_roundtrip()
  test_pipe_roundtrip_and_eof()
  test_closed_stream_errors()
  test_cancellation_cancels_blocked_read()

  test_read_line_variants()
  test_read_all_and_exactly()
  test_read_numeric_formats()
  test_write_variants()
  test_merge_lines_op()
  test_stream_properties_and_rename()
end

fibers.run(main)

print("test_file.lua: all assertions passed")
