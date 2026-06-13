-- Producer/consumer half-state for Flow.
--
-- A HalfState is one small transactional state machine: open, shut down, or
-- failed. Flow composes a producer half and a consumer half; the buffer does not
-- know about EOF, broken pipes, or errors.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')
local OpPack = Op._pack

local Half = {}
Half.__index = Half
local HalfKind = { name = 'flow_half' }
local next_id = 0

local function ensure_record(c, h, version)
  local rec = Resource.ensure(c, h, HalfKind)
  rec.read = rec.read or (version or h.version or 0)
  return rec
end

local function state_from(h, rec)
  return {
    half = h,
    role = h.role,
    open = rec and rec.has_open and rec.open or h.open,
    error = rec and rec.has_error and rec.error or h.error,
    reason = rec and rec.has_reason and rec.reason or h.reason,
    version = h.version or 0,
  }
end

local function read_only(h, version, ...)
  local c = Candidate.new(OpPack(...))
  ensure_record(c, h, version)
  return c
end

local function wake_set(h)
  return Versioned.wake_set('flow:half:changed', h._fibers_id, { half = h })
end

function HalfKind.clone(rec)
  return { kind = HalfKind, read = rec.read, has_open = rec.has_open, open = rec.open, has_error = rec.has_error, error = rec.error, has_reason = rec.has_reason, reason = rec.reason }
end

function HalfKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_open then dst.has_open = true; dst.open = src.open end
  if src.has_error then dst.has_error = true; dst.error = src.error end
  if src.has_reason then dst.has_reason = true; dst.reason = src.reason end
  return true
end

function HalfKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_open then
    if dst.has_open and dst.open ~= src.open then return false, Errors.HALF_OPEN_CONFLICT end
    dst.has_open = true; dst.open = src.open
  end
  if src.has_error then
    if dst.has_error and dst.error ~= src.error then return false, Errors.HALF_ERROR_CONFLICT end
    dst.has_error = true; dst.error = src.error
  end
  if src.has_reason then dst.has_reason = true; dst.reason = src.reason end
  return true
end

function HalfKind.project(half, rec, query)
  local st = state_from(half, rec)
  if query == 'state' or query == 'snapshot' then return st, true end
  if query == 'open' then return st.open, true end
  if query == 'error' then return st.error, true end
  return nil, false
end

function HalfKind.prepare(half, rec, _resolve)
  if rec.read ~= nil and (half.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.has_open and not rec.has_error and not rec.has_reason then return nil, nil, true end
  local set, err = wake_set(half)
  if err then return nil, err end
  return { kind = HalfKind, resource = half, has_open = rec.has_open, open = rec.open, has_error = rec.has_error, error = rec.error, has_reason = rec.has_reason, reason = rec.reason, consequence_set = set }
end

function HalfKind.apply(prepared, _log)
  local h = prepared.resource
  if prepared.has_open then h.open = prepared.open end
  if prepared.has_error then h.error = prepared.error end
  if prepared.has_reason then h.reason = prepared.reason end
  h.version = (h.version or 0) + 1
end

function HalfKind.eval(half, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, half)
  local rec = Versioned.overlay_rec(ctx, half)
  local st = state_from(half, rec)
  if op == 'state' then return Result.cands({ read_only(half, version, st) })
  elseif op == 'require_open' then
    if st.error then return Result.cands({ read_only(half, version, nil, st.error) }) end
    if not st.open then return Result.cands({ read_only(half, version, nil, payload.closed_error or Errors.CLOSED) }) end
    return Result.cands({ read_only(half, version, true) })
  elseif op == 'shutdown' then
    if not st.open then return Result.cands({ read_only(half, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, half, version)
    r.has_open = true; r.open = false; r.has_reason = true; r.reason = payload.reason
    return Result.cands({ c })
  elseif op == 'fail' then
    if st.error == payload.error then return Result.cands({ read_only(half, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, half, version)
    r.has_error = true; r.error = payload.error or Errors.FLOW_ERROR; r.has_open = true; r.open = false
    return Result.cands({ c })
  elseif op == 'changed' then
    if version ~= payload.version then return Result.cands({ read_only(half, version, st) }) end
    return Result.wait(Wait.resource('flow:half:changed', half._fibers_id, half, { op = 'changed', version = payload.version }))
  end
  error('unknown Flow half operation ' .. tostring(op), 2)
end

function HalfKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

function Half.new(role, name)
  next_id = next_id + 1
  local id = 'flow-half-' .. tostring(next_id)
  return setmetatable({ role = role or 'half', open = true, error = nil, reason = nil, version = 0, name = name or id, _fibers_id = id, _fibers_kind = HalfKind }, Half)
end

function Half:state_op() return Op._resource(self, HalfKind, { op = 'state' }) end
function Half:require_open_op(closed_error) return Op._resource(self, HalfKind, { op = 'require_open', closed_error = closed_error }) end
function Half:shutdown_op(reason) return Op._resource(self, HalfKind, { op = 'shutdown', reason = reason }) end
function Half:fail_op(err) return Op._resource(self, HalfKind, { op = 'fail', error = err or Errors.FLOW_ERROR }) end
function Half:changed_op(version) return Op._resource(self, HalfKind, { op = 'changed', version = version }) end

Half.Kind = HalfKind
return Half
