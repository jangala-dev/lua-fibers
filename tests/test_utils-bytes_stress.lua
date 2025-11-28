-- tests/test_bytes_stress.lua
--
-- Stress tests for fibers.utils.bytes
--  - always exercises the pure Lua backend
--  - also exercises the FFI backend if available
--
-- Uses a simple reference model (Lua strings) to verify correctness
-- under randomised workloads, via the unified string-level interface:
--   RingBuf:put(str), RingBuf:take(n), RingBuf:tostring()
--   LinearBuf:append(str), LinearBuf:tostring()

print('testing: fibers.utils.bytes stress')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local bytes = require "fibers.utils.bytes"

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format(
      "%s (expected %q, got %q)",
      msg or "assert_eq failed",
      tostring(expected),
      tostring(actual)
    ))
  end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function random_bytes(len)
  -- Deterministic pseudo-random ASCII payload; simple but fine for testing.
  local t = {}
  for i = 1, len do
    local b = 32 + ((i * 37) % 90)  -- printable range
    t[i] = string.char(b)
  end
  return table.concat(t)
end

----------------------------------------------------------------------
-- RingBuf stress: random reads/writes checked against string model
----------------------------------------------------------------------

local function stress_ring(impl, label)
  local RingBuf = impl.RingBuf
  print(("  RingBuf stress (%s)..."):format(label))

  -- Use a modest capacity so wrap-around / full conditions are exercised.
  local cap = 4096
  local rb  = RingBuf.new(cap)

  -- Reference model: Lua string containing unread data.
  local ref = ""

  math.randomseed(12345)

  local iterations = 20000

  for step = 1, iterations do
    local do_write
    if #ref == 0 then
      do_write = true
    elseif rb:write_avail() == 0 then
      do_write = false
    else
      do_write = (math.random() < 0.5)
    end

    if do_write then
      -- Write between 1 and 64 bytes, limited by write_avail.
      local max_len = math.min(64, rb:write_avail())
      if max_len > 0 then
        local len   = math.random(1, max_len)
        local chunk = random_bytes(len)

        rb:put(chunk)
        ref = ref .. chunk
      end
    else
      -- Read between 1 and 32 bytes, limited by read_avail/ref length.
      local avail = rb:read_avail()
      if avail > 0 then
        local max_len = math.min(32, avail, #ref)
        local len     = math.random(1, max_len)

        local got = rb:take(len)
        local exp = ref:sub(1, len)
        if got ~= exp then
          error(string.format(
            "RingBuf stress mismatch at step %d: expected %q, got %q",
            step, exp, got
          ))
        end
        ref = ref:sub(len + 1)
      end
    end

    -- Occasionally cross-check the snapshot.
    if step % 5000 == 0 then
      local snap = rb:tostring()
      if snap ~= ref then
        error(string.format("RingBuf snapshot mismatch at step %d", step))
      end
    end
  end

  -- Final consistency check.
  local snap = rb:tostring()
  assert_eq(snap, ref, "RingBuf final snapshot mismatch")
end

----------------------------------------------------------------------
-- LinearBuf stress: random appends and resets
----------------------------------------------------------------------

local function stress_linear(impl, label)
  local LinearBuf = impl.LinearBuf
  print(("  LinearBuf stress (%s)..."):format(label))

  -- FFI backend may honour a capacity; Lua backend may ignore it.
  local cap = 128
  local lb  = LinearBuf.new(cap)

  local ref = ""
  math.randomseed(54321)

  local iterations = 10000

  for step = 1, iterations do
    -- Occasionally reset to exercise that path as well.
    if step % 2000 == 0 then
      lb:reset()
      ref = ""
    end

    local len = math.random(0, 128)
    if len == 0 then
      -- Occasionally just check without changing.
      local snap = lb:tostring()
      if snap ~= ref then
        error(string.format("LinearBuf snapshot mismatch at step %d", step))
      end
    else
      local chunk = random_bytes(len)
      lb:append(chunk)
      ref = ref .. chunk
    end

    if step % 2500 == 0 then
      local snap = lb:tostring()
      if snap ~= ref then
        error(string.format("LinearBuf snapshot mismatch at step %d", step))
      end
    end
  end

  local snap = lb:tostring()
  assert_eq(snap, ref, "LinearBuf final snapshot mismatch")
end

----------------------------------------------------------------------
-- Run backends
----------------------------------------------------------------------

local function run_backend(label, impl)
  print(("testing bytes backend (stress): %s"):format(label))
  stress_ring(impl, label)
  stress_linear(impl, label)
  print(("backend %s: OK\n"):format(label))
end

print("testing fibers.utils.bytes (stress)")

-- Always test pure Lua backend
if not bytes.lua or not bytes.lua.RingBuf or not bytes.lua.LinearBuf then
  error("bytes.lua backend not available")
end
run_backend("lua", bytes.lua)

-- Test FFI backend if present
if bytes.ffi and bytes.ffi.RingBuf and bytes.ffi.LinearBuf then
  run_backend("ffi", bytes.ffi)
else
  print("ffi backend not available; skipping FFI stress\n")
end

print("all bytes stress tests done")
