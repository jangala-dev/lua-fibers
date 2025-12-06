-- fibers.utils.time
--
-- Top-level time provider shim.
--
-- Backends (priority order):
--   1. fibers.utils.time.ffi    - clock_gettime + nanosleep (via ffi_compat)
--   2. fibers.utils.time.posix  - luaposix clock_gettime/gettimeofday
--   3. fibers.utils.time.linux  - /proc/uptime or os.time + os.execute("sleep")
--
---@module 'fibers.utils.time'

local candidates = {
  'fibers.utils.time.ffi',
  'fibers.utils.time.posix',
  'fibers.utils.time.linux',
}

local chosen

for _, name in ipairs(candidates) do
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" and mod.is_supported and mod.is_supported() then
    chosen = mod
    break
  end
end

if not chosen then
  error("fibers.utils.time: no suitable time backend available on this platform")
end

local function now()
  return chosen.now()
end

--- Best-effort process-blocking, non-busy sleep.
---
--- Intended only for the scheduler path when no poller task source is
--- installed. In normal operation you should continue to use the
--- scheduler-based fibres.sleep module.
---@param dt number
local function sleep_blocking(dt)
  if dt <= 0 then return end

  if type(chosen.sleep) == "function" then
    return chosen.sleep(dt)
  end

  -- Last resort: busy loop on now(). This path should only be used in
  -- very constrained environments.
  local start = now()
  while now() - start < dt do end
end

return {
  now            = now,
  resolution     = chosen.resolution,
  source         = chosen.source or chosen.impl,
  impl           = chosen.impl,
  monotonic      = chosen.monotonic ~= false,
  sleep_blocking = sleep_blocking,
}
