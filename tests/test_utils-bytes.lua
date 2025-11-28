-- tests/test_utils-bytes.lua

print('testing: fibers.utils.bytes')

-- look one level up
package.path = "../src/?.lua;" .. package.path

-- Tests for fibers.utils.bytes
--  - always exercises the pure Lua backend
--  - additionally exercises the FFI backend if available
--  - all backends are tested via the unified string-level API:
--        RingBuf:  new, read_avail, write_avail, is_empty, put, take,
--                  tostring, find, reset
--        LinearBuf:new, append, tostring, reset
--    plus an extra FFI-only test for reserve/commit on LinearBuf.

local function get_ffi()
  local is_LuaJIT = rawget(_G, "jit") and true or false
  local ok, ffi
  if is_LuaJIT then
    ok, ffi = pcall(require, "ffi")
  else
    ok, ffi = pcall(require, "cffi")
  end
  if not ok then return nil end
  return ffi
end

local bytes = require "fibers.utils.bytes"
local ffi   = get_ffi()

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s (expected %q, got %q)",
      msg or "assert_eq failed",
      tostring(expected),
      tostring(actual)))
  end
end

------------------------------------------------------------
-- Backend-independent tests (string-level API)
------------------------------------------------------------

local function test_ring_basic(impl)
  local RingBuf = impl.RingBuf
  print("  RingBuf basic...")

  local rb = RingBuf.new(16)

  assert_eq(rb:read_avail(), 0,   "read_avail at start")
  assert_eq(rb:write_avail(), 16, "write_avail at start")
  assert(rb:is_empty(),             "is_empty at start")
  assert(not rb:is_full(),          "is_full at start")

  -- Write "hello"
  rb:put("hello")
  assert_eq(rb:read_avail(), 5,    "read_avail after put('hello')")
  assert_eq(rb:write_avail(), 11,  "write_avail after put('hello')")

  -- tostring should not consume
  local s_view = rb:tostring()
  assert_eq(s_view, "hello", "tostring after put 'hello'")
  assert_eq(rb:read_avail(), 5,    "read_avail unchanged after tostring")

  -- Take back
  local s = rb:take(5)
  assert_eq(s, "hello", "take(5) returns 'hello'")
  assert_eq(rb:read_avail(), 0,    "read_avail after full take")
  assert(rb:is_empty(),            "is_empty after draining")
end

local function test_ring_wrap(impl)
  local RingBuf = impl.RingBuf
  print("  RingBuf wrap-around...")

  local rb = RingBuf.new(8)  -- small to force wrap

  -- Sequence: put 6, take 4, put 4 → buffer should contain "efWXYZ"
  rb:put("abcdef")
  assert_eq(rb:read_avail(), 6, "wrap: read_avail after first put(6)")

  local s1 = rb:take(4)
  assert_eq(s1, "abcd", "wrap: first take(4)")
  assert_eq(rb:read_avail(), 2, "wrap: read_avail after first take")

  rb:put("WXYZ")
  assert_eq(rb:read_avail(), 6, "wrap: read_avail after second put(4)")

  local s_all = rb:tostring()
  assert_eq(s_all, "efWXYZ", "wrap: content after wrap sequence")

  local off = rb:find("WX")
  assert_eq(off, 2, "wrap: find('WX') offset")
end

local function test_linear_basic(impl)
  local LinearBuf = impl.LinearBuf
  print("  LinearBuf basic...")

  local lb = LinearBuf.new(32)

  lb:append("hello")
  lb:append(" world")
  assert_eq(lb:tostring(), "hello world", "LinearBuf tostring after appends")

  lb:reset()
  assert_eq(lb:tostring(), "", "LinearBuf tostring after reset")
end

------------------------------------------------------------
-- FFI-only extra test for reserve/commit on LinearBuf
------------------------------------------------------------

local function test_linear_reserve_commit_ffi(impl, ffi_obj)
  if not ffi_obj then
    return
  end
  if not impl or not impl.LinearBuf then
    return
  end

  print("  LinearBuf reserve/commit (FFI)...")

  local LinearBuf = impl.LinearBuf
  local lb = LinearBuf.new(32)

  -- reserve/commit path
  local p = lb:reserve(5)
  ffi_obj.copy(p, "hello", 5)
  lb:commit(5)
  assert_eq(lb:tostring(), "hello", "LinearBuf tostring after reserve/commit")

  -- append path on top
  lb:append(" world")
  assert_eq(lb:tostring(), "hello world", "LinearBuf tostring after append")
end

------------------------------------------------------------
-- Run tests for a given backend
------------------------------------------------------------

local function run_backend_tests(name, impl, has_ffi_flag, ffi_obj)
  print(("testing bytes backend: %s"):format(name))
  test_ring_basic(impl)
  test_ring_wrap(impl)
  test_linear_basic(impl)
  if has_ffi_flag then
    test_linear_reserve_commit_ffi(impl, ffi_obj)
  end
  print(("backend %s: OK\n"):format(name))
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

print("testing fibers.utils.bytes")

-- Always test pure Lua backend
if not bytes.lua or not bytes.lua.RingBuf or not bytes.lua.LinearBuf then
  error("bytes.lua backend not available")
end

run_backend_tests("lua", bytes.lua, false, nil)

-- Test FFI backend if present
if bytes.ffi and bytes.ffi.RingBuf and bytes.ffi.LinearBuf and ffi then
  run_backend_tests("ffi", bytes.ffi, true, ffi)
else
  print("ffi backend not available or no ffi/cffi; skipping FFI tests\n")
end

print("all bytes tests done")
