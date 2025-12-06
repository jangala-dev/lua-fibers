-- fibers.utils.time.ffi
--
-- FFI-based time provider using clock_gettime() and nanosleep().
--
---@module 'fibers.utils.time.ffi'

local core   = require 'fibers.utils.time.core'
local ffi_c  = require 'fibers.utils.ffi_compat'

if not (ffi_c.is_supported and ffi_c.is_supported()) then
  return { is_supported = function() return false end }
end

local ffi    = ffi_c.ffi
local C      = ffi_c.C
local toint  = ffi_c.tonumber
local errno  = ffi_c.errno

ffi.cdef[[
  typedef long time_t;
  struct timespec {
    time_t tv_sec;
    long   tv_nsec;
  };

  int clock_gettime(int clk_id, struct timespec *tp);
  int nanosleep(const struct timespec *req, struct timespec *rem);

  char *strerror(int errnum);
]]

-- Linux / POSIX clock ids.
local CLOCK_MONOTONIC     = 1
local CLOCK_MONOTONIC_RAW = 4

local EINTR = 4

local function strerror(e)
  local s = C.strerror(e)
  if s == nil then
    return "errno " .. tostring(e)
  end
  return ffi.string(s)
end

local function make_now(clock_id)
  local ts = ffi.new("struct timespec[1]")

  return function()
    local rc = toint(C.clock_gettime(clock_id, ts))
    if rc ~= 0 then
      local e = errno()
      error("clock_gettime failed: " .. strerror(e))
    end
    local t = ts[0]
    return tonumber(t.tv_sec) + tonumber(t.tv_nsec) * 1e-9
  end
end

local function probe_clock(clock_id)
  local ok, now_or_err = pcall(make_now, clock_id)
  if not ok then
    return nil, now_or_err
  end
  local now = now_or_err

  local ok2, t = pcall(now)
  if not ok2 or type(t) ~= "number" then
    return nil, t
  end

  return now, nil
end

local function sleep_blocking(dt)
  if dt <= 0 then return end

  local sec  = math.floor(dt)
  local nsec = math.floor((dt - sec) * 1e9)
  if nsec < 0 then nsec = 0 end
  if nsec >= 1e9 then
    sec  = sec + 1
    nsec = nsec - 1e9
  end

  local req = ffi.new("struct timespec[1]")
  req[0].tv_sec  = sec
  req[0].tv_nsec = nsec

  while true do
    local rc = toint(C.nanosleep(req, req))
    if rc == 0 then
      break
    end
    local e = errno()
    if e ~= EINTR then
      break
    end
    -- EINTR: req now holds remaining time; loop again.
  end
end

local function build()
  -- Prefer MONOTONIC_RAW, fall back to MONOTONIC.
  local now, err = probe_clock(CLOCK_MONOTONIC_RAW)
  local impl     = "ffi.clock_gettime(CLOCK_MONOTONIC_RAW)"

  if not now then
    now, err = probe_clock(CLOCK_MONOTONIC)
    impl     = "ffi.clock_gettime(CLOCK_MONOTONIC)"
  end

  if not now then
    error(err or "no usable clock_gettime clock")
  end

  local src = core.build_source{
    name      = "clock_gettime",
    impl      = impl,
    monotonic = true,
    now       = now,
    sleep     = sleep_blocking,
  }

  src.resolution = src.resolution or core.estimate_resolution(src.now)

  return src
end

local function is_supported()
  local ok, res = pcall(build)
  if not ok then
    return false
  end
  return res and true or false
end

if not is_supported() then
  return { is_supported = function() return false end }
end

local src = build()

return {
  is_supported = is_supported,
  now          = src.now,
  resolution   = src.resolution,
  source       = src.name,
  impl         = src.impl,
  monotonic    = src.monotonic,
  sleep        = src.sleep,
}
