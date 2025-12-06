-- fibers.utils.time.posix
--
-- luaposix-based time provider using clock_gettime() or gettimeofday().
--
---@module 'fibers.utils.time.posix'

local core = require 'fibers.utils.time.core'

local ok_time, ptime = pcall(require, 'posix.sys.time')
if not ok_time or type(ptime) ~= "table" then
  return { is_supported = function() return false end }
end

local function errno_msg(prefix, err, eno)
  if err and err ~= "" then
    return err
  end
  if eno then
    return ("%s (errno %d)"):format(prefix, eno)
  end
  return prefix
end

local function has_clock_gettime()
  return type(ptime.clock_gettime) == "function"
end

local function build_now_clock()
  local clk_id = ptime.CLOCK_MONOTONIC or "monotonic"

  local function now()
    local ts, err, eno = ptime.clock_gettime(clk_id)
    if not ts then
      error(errno_msg("clock_gettime failed", err, eno))
    end
    return ts.tv_sec + ts.tv_nsec * 1e-9
  end

  local t = now()
  assert(type(t) == "number", "clock_gettime did not yield a number")

  return now
end

local function build_now_gettimeofday()
  assert(type(ptime.gettimeofday) == "function",
    "no clock_gettime and no gettimeofday")

  local function now()
    local tv, err, eno = ptime.gettimeofday()
      if not tv then
        error(errno_msg("gettimeofday failed", err, eno))
      end
      return tv.tv_sec + tv.tv_usec * 1e-6
  end

  return now, false
end

local function build()
  local now, monotonic

  if has_clock_gettime() then
    now       = build_now_clock()
    monotonic = true
  else
    now, monotonic = build_now_gettimeofday()
  end

  local src = core.build_source{
    name      = "luaposix time",
    impl      = has_clock_gettime() and "posix.clock_gettime" or "posix.gettimeofday",
    monotonic = monotonic,
    now       = now,
    -- sleep: left nil; higher layers use pollers or the linux backend for blocking sleep.
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
}
