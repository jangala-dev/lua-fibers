-- Optional pump in-flight claim state for Flow host drainers.
--
-- Claim is deliberately not part of ordinary Flow semantics. Pump strategies use
-- it when irreversible host writes need a two-phase claim/ack protocol.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')
local OpPack = Op._pack

local Claim = {}
Claim.__index = Claim
local ClaimKind = { name = 'flow_claim' }
local next_id = 0

local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then error((label or 'Flow claim count') .. ' must be a non-negative integer', 3) end
  return n
end

local function ensure_record(c, claim, version)
  local rec = Resource.ensure(c, claim, ClaimKind)
  rec.read = rec.read or (version or claim.version or 0)
  return rec
end

local function state_from(claim, rec)
  local has = rec and rec.has_state
  return {
    claim = claim,
    id = has and rec.id or claim.id,
    bytes = has and (rec.bytes or '') or (claim.bytes or ''),
    version = claim.version or 0,
  }
end

local function read_only(claim, version, ...)
  local c = Candidate.new(OpPack(...))
  ensure_record(c, claim, version)
  return c
end

local function wake_set(claim)
  return Versioned.wake_set('flow:claim:changed', claim._fibers_id, { claim = claim })
end

function ClaimKind.clone(rec)
  return { kind = ClaimKind, read = rec.read, has_state = rec.has_state, id = rec.id, bytes = rec.bytes }
end

function ClaimKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_state then dst.has_state = true; dst.id = src.id; dst.bytes = src.bytes end
  return true
end

function ClaimKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_state then
    if dst.has_state and (dst.id ~= src.id or dst.bytes ~= src.bytes) then return false, Errors.CLAIM_CONFLICT end
    dst.has_state = true; dst.id = src.id; dst.bytes = src.bytes
  end
  return true
end

function ClaimKind.project(claim, rec, query)
  local st = state_from(claim, rec)
  if query == 'inspect' or query == 'snapshot' then return st, true end
  if query == 'bytes' then return st.bytes, true end
  if query == 'empty' then return (st.bytes or '') == '', true end
  return nil, false
end

function ClaimKind.prepare(claim, rec, _resolve)
  if rec.read ~= nil and (claim.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.has_state then return nil, nil, true end
  local set, err = wake_set(claim)
  if err then return nil, err end
  return { kind = ClaimKind, resource = claim, id = rec.id, bytes = rec.bytes or '', consequence_set = set }
end

function ClaimKind.apply(prepared, _log)
  local claim = prepared.resource
  claim.id = prepared.id
  claim.bytes = prepared.bytes or ''
  claim.version = (claim.version or 0) + 1
end

function ClaimKind.eval(claim, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, claim)
  local rec = Versioned.overlay_rec(ctx, claim)
  local st = state_from(claim, rec)
  if op == 'inspect' then
    return Result.cands({ read_only(claim, version, st) })
  elseif op == 'inflight' then
    if (st.bytes or '') ~= '' then return Result.cands({ read_only(claim, version, st.id, st.bytes) }) end
    return Result.wait(Wait.resource('flow:claim:changed', claim._fibers_id, claim, { op = 'inflight', version = version }))
  elseif op == 'set' then
    if (st.bytes or '') ~= '' then return Result.cands({ read_only(claim, version, nil, Errors.CLAIM_ALREADY_IN_FLIGHT) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, claim, version)
    r.has_state = true; r.id = payload.id; r.bytes = payload.bytes or ''
    return Result.cands({ c })
  elseif op == 'ack' then
    local n = as_nonneg_int(payload.n, 0, 'Flow claim acknowledgement')
    if (st.bytes or '') == '' then return Result.cands({ read_only(claim, version, nil, Errors.NO_INFLIGHT_CLAIM) }) end
    if st.id ~= payload.id then return Result.cands({ read_only(claim, version, nil, Errors.STALE_CLAIM) }) end
    if n > #(st.bytes or '') then return Result.cands({ read_only(claim, version, nil, Errors.CLAIM_ACK_TOO_LARGE) }) end
    local remaining = string.sub(st.bytes or '', n + 1)
    local c = Candidate.new(OpPack(true, n, remaining))
    local r = ensure_record(c, claim, version)
    r.has_state = true; r.id = remaining ~= '' and st.id or nil; r.bytes = remaining
    return Result.cands({ c })
  elseif op == 'clear' then
    if (st.bytes or '') == '' then return Result.cands({ read_only(claim, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, claim, version)
    r.has_state = true; r.id = nil; r.bytes = ''
    return Result.cands({ c })
  elseif op == 'empty' then
    if (st.bytes or '') == '' then return Result.cands({ read_only(claim, version, true) }) end
    return Result.wait(Wait.resource('flow:claim:changed', claim._fibers_id, claim, { op = 'empty', version = version }))
  elseif op == 'changed' then
    if version ~= payload.version then return Result.cands({ read_only(claim, version, state_from(claim, rec)) }) end
    return Result.wait(Wait.resource('flow:claim:changed', claim._fibers_id, claim, { op = 'changed', version = payload.version }))
  end
  error('unknown Flow claim operation ' .. tostring(op), 2)
end

function ClaimKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

function Claim.new(name)
  next_id = next_id + 1
  local id = 'flow-claim-' .. tostring(next_id)
  return setmetatable({ id = nil, bytes = '', version = 0, name = name or id, _fibers_id = id, _fibers_kind = ClaimKind }, Claim)
end

function Claim:inspect_op() return Op._resource(self, ClaimKind, { op = 'inspect' }) end
function Claim:inflight_op() return Op._resource(self, ClaimKind, { op = 'inflight' }) end
function Claim:set_op(id, bytes) if type(id) ~= 'string' then error('Flow claim set expects an id', 2) end; return Op._resource(self, ClaimKind, { op = 'set', id = id, bytes = bytes or '' }) end
function Claim:ack_op(id, n) if type(id) ~= 'string' then error('Flow claim acknowledgement expects a claim id', 2) end; return Op._resource(self, ClaimKind, { op = 'ack', id = id, n = as_nonneg_int(n, 0, 'Flow claim acknowledgement') }) end
function Claim:clear_op() return Op._resource(self, ClaimKind, { op = 'clear' }) end
function Claim:empty_op() return Op._resource(self, ClaimKind, { op = 'empty' }) end
function Claim:changed_op(version) return Op._resource(self, ClaimKind, { op = 'changed', version = version }) end
function Claim:debug_bytes() return self.bytes ~= '' and self.bytes or nil end

Claim.Kind = ClaimKind
return Claim
