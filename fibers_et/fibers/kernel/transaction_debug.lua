-- Deliberate test/debug entry points for transaction-net proof artefacts.
--
-- Production code should not reach into Runtime private fields, construct
-- Solver objects directly, or depend on retained prepared worlds.  Tests that
-- need to inspect proof caches, observers, worlds or pending signatures should
-- use this module instead.

local Net = require('fibers.kernel.transaction_net')
local Resources = require('fibers.kernel.resources')
local Proof = require('fibers.kernel.proof')
local Capture = Proof.Capture

local Debug = {}

function Debug.pending_signature(pending)
  return Net.pending_signature(pending)
end

function Debug.wait_cache(rt)
  return rt and rt._net_wait_cache or nil
end

function Debug.wait_cache_observer(rt)
  local cache = Debug.wait_cache(rt)
  return cache and cache.observer or nil
end

function Debug.wait_cache_valid(rt)
  local observer = Debug.wait_cache_observer(rt)
  return observer ~= nil and Resources.observer_valid(observer) or false
end

function Debug.cursor(rt)
  return rt and rt._cursor or nil
end

function Debug.cursor_valid(rt)
  local cursor = Debug.cursor(rt)
  return cursor ~= nil and cursor:is_valid(rt, rt._waiting or {}) or false
end


function Debug.perform_sync(rt, op)
  local solver = Net.Solver.new(rt, {})
  return solver:perform_sync(op)
end

function Debug.new_pending(op, id, fiber, attempt)
  id = id or 1
  return { [id] = { op = op, fiber = fiber, attempt = attempt or {} } }
end

function Debug.solve(rt, pending, opts)
  opts = opts or {}
  local solver = Net.Solver.new(rt, pending)
  if opts.debug then
    solver.capture = Capture.debug()
  elseif opts.retain then
    solver.capture = Capture.frontiers()
  end
  local out = solver:find_commit_outcome()
  if out and out.world and (opts.retain or opts.debug) then
    local world = out.world
    if world.observer == nil then
      world.observer = Resources.new_observer('world', world)
      Resources.register_env_frontiers(world.env, world.observer)
    end
    world.valid = world.valid ~= false
    if opts.debug and world.validate_debug_observations and not world:validate_debug_observations(rt) then
      world.valid = false
      out = { tag = 'unknown', waits = {}, reason = 'stale-observation' }
    end
  end
  return out, solver
end

function Debug.probe_world(rt, op, opts)
  opts = opts or {}
  local id = opts.id or 1
  local pending = opts.pending or Debug.new_pending(op, id, opts.fiber, opts.attempt)
  local out, solver = Debug.solve(rt, pending, opts)
  return out and out.world or nil, pending, out, solver
end

function Debug.valid(x, rt)
  if not x then return false end
  local observer_ok = true
  if x.observer then observer_ok = Resources.observer_valid(x.observer) end
  if x.valid ~= nil then return x.valid ~= false and observer_ok end
  if x.validate then return x:validate() end
  if x.observer then return Resources.observer_valid(x.observer) end
  if x.observations then return Resources.observer_valid(x) end
  if x.observer == nil and x.pending_sig ~= nil then return false end
  return true
end

function Debug.invalidated_by(x)
  if not x then return nil, nil end
  local observer = x.observer or x
  return x.invalidated_by or observer.invalidated_by, x.invalidated_reason or observer.invalidated_reason
end

function Debug.observed_frontiers(x)
  local observer = x and (x.observer or x)
  local out = {}
  for i = 1, #(observer and observer.observations or {}) do
    local item = observer.observations[i]
    out[#out + 1] = item and (item.frontier or item)
  end
  return out
end

return Debug
