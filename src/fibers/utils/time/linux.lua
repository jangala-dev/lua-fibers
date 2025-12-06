-- fibers.utils.time.linux
--
-- Generic Linux / POSIX fallback time provider.
--
-- Strategy:
--   * Probe os.execute("sleep 0.01") to see if shell sleep exists and
--     accepts fractional seconds.
--   * If that succeeds and /proc/uptime is available, use /proc/uptime
--     for a monotonic clock and fractional "sleep dt".
--   * Otherwise, fall back to os.time() and integer-second sleep.
--
---@module 'fibers.utils.time.linux'

local core = require 'fibers.utils.time.core'

local UPTIME_PATH = "/proc/uptime"

local function have_proc_uptime()
  local f = io.open(UPTIME_PATH, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

local function read_uptime()
  local f = io.open(UPTIME_PATH, "r")
  if not f then
    return nil
  end
  local line = f:read("*l")
  f:close()
  if not line then
    return nil
  end
  local first = line:match("^%s*([0-9]+%.?[0-9]*)")
  if not first then
    return nil
  end
  return tonumber(first)
end

--- Normalise os.execute return across Lua versions.
---@param cmd string
---@return boolean ok
local function command_succeeds(cmd)
  if type(os) ~= "table" or type(os.execute) ~= "function" then
    return false
  end

  local ok, a, b = pcall(os.execute, cmd)
  if not ok then
    return false
  end

  -- Lua 5.2+: ok==true, a is true/nil/"exit"/"signal".
  if a == true then
    return true
  end
  if type(a) == "number" then
    return a == 0
  end
  if a == "exit" then
    return b == 0
  end

  -- Lua 5.1: rc is numeric status.
  if a ~= nil and b == nil and type(a) ~= "string" then
    return a == 0
  end

  return false
end

local function probe_sleep()
  if type(os) ~= "table" or type(os.execute) ~= "function" then
    return { available = false, fractional = false }
  end

  -- Prefer to test fractional first.
  if command_succeeds("sleep 0.01") then
    return { available = true, fractional = true }
  end

  -- Fall back to integral only.
  if command_succeeds("sleep 1") then
    return { available = true, fractional = false }
  end

  return { available = false, fractional = false }
end

local function build()
  local sleep_info = probe_sleep()
  local have_sleep = sleep_info.available
  local frac_sleep = sleep_info.fractional

  local now
  local impl
  local monotonic

  if have_proc_uptime() and frac_sleep then
    local base = read_uptime()
    assert(type(base) == "number", "failed to read /proc/uptime")

    now = function()
      local t = read_uptime()
      if not t then
        error("failed to read /proc/uptime")
      end
      return t - base
    end

    impl      = "linux.proc_uptime"
    monotonic = true
  else
    -- Coarse wall-clock baseline; only used as a last resort.
    now       = function() return os.time() end
    impl      = "os.time"
    monotonic = false
  end

  local sleep_fn
  if have_sleep then
    sleep_fn = function(dt)
      if dt <= 0 then
        return
      end

      if frac_sleep then
        local secs = dt
        if secs > 86400 then
          secs = 86400
        elseif secs < 0 then
          secs = 0
        end
        local cmd = ("sleep %.6f"):format(secs)
        command_succeeds(cmd)
      else
        local secs = math.ceil(dt)
        if secs < 1 then
          secs = 1
        end
        local cmd = ("sleep %d"):format(secs)
        command_succeeds(cmd)
      end
    end
  end

  local src = core.build_source{
    name      = "Linux fallback time",
    impl      = impl,
    monotonic = monotonic,
    now       = now,
    sleep     = sleep_fn,
  }

  if impl == "linux.proc_uptime" then
    src.resolution = src.resolution or core.estimate_resolution(src.now, 64)
  else
    -- os.time() is normally second-resolution.
    src.resolution = 1.0
  end

  return src
end

local function is_supported()
  -- This is intended as a generic Posix/Linux fallback, so be permissive:
  -- require a usable os table at least.
  return type(os) == "table"
end

if not is_supported() then
  return { is_supported = function() return false end }
end

local src = build()

return {
  is_supported = function() return true end,
  now          = src.now,
  resolution   = src.resolution,
  source       = src.name,
  impl         = src.impl,
  monotonic    = src.monotonic,
  sleep        = src.sleep,
}
