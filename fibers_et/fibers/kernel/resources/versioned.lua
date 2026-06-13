-- Small helpers for simple versioned transactional resources.
--
-- This intentionally does not generate resource kinds. It only centralises the
-- common mechanics used by small resources: observed version, read-only
-- candidates, typed wakes, and changed waits.

local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Resource = require('fibers.kernel.resources.protocol')
local ConsequenceSet = require('fibers.kernel.consequence.set')
local Wait = require('fibers.kernel.wait')
local Effect = require('fibers.base.effect')

local Versioned = {}

function Versioned.observe(ctx, obj)
  if ctx and ctx.observe_version then return ctx.observe_version(ctx, obj) end
  return obj.version or 0
end

function Versioned.overlay_rec(ctx, obj)
  local overlay = ctx and ctx.overlay
  return overlay and overlay.res and overlay.res[obj] or nil
end

function Versioned.ensure(c, obj, kind, version)
  local rec = Resource.ensure(c, obj, kind)
  rec.read = rec.read or (version or obj.version or 0)
  return rec
end

function Versioned.read_only(obj, kind, version, pack, ...)
  local c = Candidate.new(pack(...))
  Versioned.ensure(c, obj, kind, version)
  return c
end

function Versioned.wake_set(wait_kind, key, payload)
  local set = ConsequenceSet.empty()
  local ok, err = set:add(Effect.wake(wait_kind, key, payload))
  if not ok then return nil, err end
  return set
end

function Versioned.changed_result(obj, kind, version, wait_kind, payload, pack, value)
  local current = obj.version or 0
  if version ~= current then
    return Result.cands({ Versioned.read_only(obj, kind, current, pack, value) })
  end
  return Result.wait(Wait.resource(wait_kind, obj._fibers_id, obj, payload))
end

return Versioned
