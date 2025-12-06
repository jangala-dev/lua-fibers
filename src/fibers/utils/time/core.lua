-- fibers.utils.time.core
--
-- Contract and helpers for time providers.

---@module 'fibers.utils.time.core'

---@class TimeSourceOps
---@field name string|nil
---@field impl string|nil
---@field monotonic boolean|nil
---@field now fun(): number
---@field resolution number|nil
---@field sleep fun(dt:number)|nil  -- optional process-blocking sleep

---@class TimeSource
---@field name string
---@field impl string
---@field monotonic boolean
---@field now fun(): number
---@field resolution number|nil
---@field sleep fun(dt:number)|nil

local M = {}

--- Build a normalised TimeSource from a backend ops table.
---@param ops TimeSourceOps
---@return TimeSource
function M.build_source(ops)
  assert(type(ops) == "table", "time source ops must be a table")
  assert(type(ops.now) == "function", "time source requires now()")

  local src = {
    name       = ops.name or "time",
    impl       = ops.impl or ops.name or "time",
    monotonic  = ops.monotonic ~= false,
    now        = ops.now,
    resolution = ops.resolution,
    sleep      = ops.sleep,
  }

  return src
end

--- Estimate timer resolution by sampling consecutive now() calls.
---
--- This is inherently a busy-loop; only use at initialisation.
---@param now_fn fun(): number
---@param samples? integer
---@return number|nil
function M.estimate_resolution(now_fn, samples)
  samples = samples or 256
  assert(type(now_fn) == "function", "estimate_resolution: now_fn must be a function")

  local best = math.huge
  local last = now_fn()

  for _ = 1, samples do
    local t  = now_fn()
    local dt = t - last
    last     = t
    if dt > 0 and dt < best then
      best = dt
    end
  end

  if best == math.huge or best <= 0 then
    return nil
  end
  return best
end

return M
