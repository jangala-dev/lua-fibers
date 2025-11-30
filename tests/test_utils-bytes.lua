print('testing: fibers.utils.bytes')

-- look one level up
package.path = "../src/?.lua;" .. package.path

-- Tests for fibers.utils.bytes
--  - always exercises the pure Lua backend
--  - additionally exercises the FFI backend if available
--  - also exercises the top-level shim (whatever it chooses)
--  - all backends are tested via the unified string-level API:
--        RingBuf:  new, read_avail, write_avail, is_empty, put, take,
--                  tostring, find, reset
--        LinearBuf:new, append, tostring, reset
--    plus an extra FFI-only test for reserve/commit on LinearBuf,
--    but only if the object actually supports reserve/commit and an
--    ffi/cffi library is available.

local function get_ffi()
  local is_LuaJIT = rawget(_G, "jit") and true or false
  local ok, ffi_mod
  if is_LuaJIT then
    ok, ffi_mod = pcall(require, "ffi")
  else
    ok, ffi_mod = pcall(require, "cffi")
  end
  if not ok then return nil end
  return ffi_mod
end

local bytes_shim   = require "fibers.utils.bytes"
local lua_backend  = require "fibers.utils.bytes.lua"

local ok_ffi_backend, ffi_backend = pcall(require, "fibers.utils.bytes.ffi")
if not ok_ffi_backend then
  ffi_backend = nil
end

local ffi_obj = get_ffi()

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

  rb:reset()
  assert_eq(rb:read_avail(), 0, "read_avail after reset")
  assert(rb:is_empty(),         "is_empty after reset")
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
-- Optional FFI test for reserve/commit on LinearBuf
------------------------------------------------------------

local function test_linear_reserve_commit_ffi(impl, ffi_mod)
  -- Only applicable if we have an ffi/cffi module.
  if not ffi_mod then
    return
  end
  if not impl or not impl.LinearBuf or not impl.LinearBuf.new then
    return
  end

  local lb = impl.LinearBuf.new(32)

  -- Only run if this backend actually exposes a pointer-level API.
  if type(lb.reserve) ~= "function" or type(lb.commit) ~= "function" then
    return
  end

  print("  LinearBuf reserve/commit (FFI)...")

  -- reserve/commit path
  local p = lb:reserve(5)
  ffi_mod.copy(p, "hello", 5)
  lb:commit(5)
  assert_eq(lb:tostring(), "hello", "LinearBuf tostring after reserve/commit")

  -- append path on top
  lb:append(" world")
  assert_eq(lb:tostring(), "hello world", "LinearBuf tostring after append")
end

------------------------------------------------------------
-- Run tests for a given backend
------------------------------------------------------------

local function run_backend_tests(name, impl, ffi_mod)
  print(("testing bytes backend: %s"):format(name))

  if not impl or not impl.RingBuf or not impl.LinearBuf then
    error(("backend %s missing RingBuf/LinearBuf"):format(name))
  end

  test_ring_basic(impl)
  test_ring_wrap(impl)
  test_linear_basic(impl)
  test_linear_reserve_commit_ffi(impl, ffi_mod)

  print(("backend %s: OK\n"):format(name))
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

print("testing fibers.utils.bytes")

-- Always test pure Lua backend
if not lua_backend or not lua_backend.is_supported or not lua_backend.is_supported() then
  error("Lua bytes backend not available or not supported")
end
run_backend_tests("lua", lua_backend, nil)

-- Test FFI backend if present and supported
if ffi_backend and ffi_backend.is_supported and ffi_backend.is_supported() then
  if not ffi_obj then
    print("ffi backend available but no ffi/cffi library; skipping pointer-level FFI test")
  end
  run_backend_tests("ffi", ffi_backend, ffi_obj)
else
  print("ffi backend not available or not supported; skipping FFI backend tests\n")
end

-- Test the top-level shim (whatever it chose)
if bytes_shim and bytes_shim.RingBuf and bytes_shim.LinearBuf then
  run_backend_tests("shim", bytes_shim, ffi_obj)
else
  error("bytes shim backend missing RingBuf/LinearBuf")
end

print("all bytes tests done")
