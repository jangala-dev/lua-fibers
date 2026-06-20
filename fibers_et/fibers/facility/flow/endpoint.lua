-- Input/output endpoint state for Flow.
--
-- Endpoint state controls whether bytes may enter or leave a directional medium.
-- It owns terminal and failure facts; the reservoir only owns retained bytes.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')
local OpPack = Op._pack

local Endpoint = {}
Endpoint.__index = Endpoint
local EndpointKind = { name = 'flow_endpoint' }
local next_id = 0

local function ensure_record(c, ep, version)
  local rec = Resource.ensure(c, ep, EndpointKind)
  rec.read = rec.read or (version or ep.version or 0)
  return rec
end

local function state_from(ep, rec)
  local open, err, reason = ep.open, ep.error, ep.reason
  if rec and rec.has_open then open = rec.open end
  if rec and rec.has_error then err = rec.error end
  if rec and rec.has_reason then reason = rec.reason end
  return { endpoint = ep, role = ep.role, open = open, error = err, reason = reason, version = ep.version or 0 }
end

local function read_only(ep, version, ...)
  local c = Candidate.new(OpPack(...))
  ensure_record(c, ep, version)
  return c
end

local function wake_set(ep)
  return Versioned.wake_set('flow:endpoint:changed', ep._fibers_id, { endpoint = ep })
end

function EndpointKind.clone(rec)
  return { kind = EndpointKind, read = rec.read, has_open = rec.has_open, open = rec.open, has_error = rec.has_error, error = rec.error, has_reason = rec.has_reason, reason = rec.reason }
end

function EndpointKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_open then dst.has_open = true; dst.open = src.open end
  if src.has_error then dst.has_error = true; dst.error = src.error end
  if src.has_reason then dst.has_reason = true; dst.reason = src.reason end
  return true
end

function EndpointKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.has_open then
    if dst.has_open and dst.open ~= src.open then return false, Errors.ENDPOINT_OPEN_CONFLICT end
    dst.has_open = true; dst.open = src.open
  end
  if src.has_error then
    if dst.has_error and dst.error ~= src.error then return false, Errors.ENDPOINT_ERROR_CONFLICT end
    dst.has_error = true; dst.error = src.error
  end
  if src.has_reason then dst.has_reason = true; dst.reason = src.reason end
  return true
end

function EndpointKind.project(ep, rec, query)
  local st = state_from(ep, rec)
  if query == 'inspect' or query == 'snapshot' then return st, true end
  if query == 'open' then return st.open, true end
  if query == 'closed' then return not st.open, true end
  if query == 'error' then return st.error, true end
  return nil, false
end

function EndpointKind.prepare(ep, rec, _resolve)
  if rec.read ~= nil and (ep.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.has_open and not rec.has_error and not rec.has_reason then return nil, nil, true end
  local set, err = wake_set(ep)
  if err then return nil, err end
  return { kind = EndpointKind, resource = ep, has_open = rec.has_open, open = rec.open, has_error = rec.has_error, error = rec.error, has_reason = rec.has_reason, reason = rec.reason, effect_set = set }
end

function EndpointKind.apply(prepared, _log)
  local ep = prepared.resource
  if prepared.has_open then ep.open = prepared.open end
  if prepared.has_error then ep.error = prepared.error end
  if prepared.has_reason then ep.reason = prepared.reason end
  ep.version = (ep.version or 0) + 1
end

function EndpointKind.eval(ep, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, ep)
  local rec = Versioned.overlay_rec(ctx, ep)
  local st = state_from(ep, rec)
  if op == 'inspect' then return Result.cands({ read_only(ep, version, st) })
  elseif op == 'open' then
    if st.error then return Result.cands({ read_only(ep, version, nil, st.error) }) end
    if not st.open then return Result.cands({ read_only(ep, version, nil, payload.closed_error or Errors.CLOSED) }) end
    return Result.cands({ read_only(ep, version, true) })
  elseif op == 'closed' then
    if not st.open then return Result.cands({ read_only(ep, version, st.reason or true) }) end
    return Result.wait(Wait.resource('flow:endpoint:closed', ep._fibers_id, ep, { op = 'closed' }))
  elseif op == 'terminal' then
    if st.error then return Result.cands({ read_only(ep, version, nil, st.error) }) end
    if not st.open then return Result.cands({ read_only(ep, version, nil, payload.default_error or st.reason or Errors.CLOSED) }) end
    return Result.wait(Wait.resource('flow:endpoint:terminal', ep._fibers_id, ep, { op = 'terminal' }))
  elseif op == 'error' then
    if st.error then return Result.cands({ read_only(ep, version, st.error) }) end
    return Result.wait(Wait.resource('flow:endpoint:error', ep._fibers_id, ep, { op = 'error' }))
  elseif op == 'close' or op == 'shutdown' then
    if not st.open then return Result.cands({ read_only(ep, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, ep, version)
    r.has_open = true; r.open = false; r.has_reason = true; r.reason = payload.reason
    return Result.cands({ c })
  elseif op == 'fail' then
    if st.error == payload.error then return Result.cands({ read_only(ep, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, ep, version)
    r.has_error = true; r.error = payload.error or Errors.FLOW_ERROR; r.has_open = true; r.open = false
    return Result.cands({ c })
  elseif op == 'changed' then
    if version ~= payload.version then return Result.cands({ read_only(ep, version, st) }) end
    return Result.wait(Wait.resource('flow:endpoint:changed', ep._fibers_id, ep, { op = 'changed', version = payload.version }))
  end
  error('unknown Flow endpoint operation ' .. tostring(op), 2)
end

function EndpointKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

function Endpoint.new(role, name)
  next_id = next_id + 1
  local id = 'flow-endpoint-' .. tostring(next_id)
  return setmetatable({ role = role or 'endpoint', open = true, error = nil, reason = nil, version = 0, name = name or id, _fibers_id = id, _fibers_kind = EndpointKind }, Endpoint)
end

function Endpoint:inspect_op() return Op._resource(self, EndpointKind, { op = 'inspect' }) end
function Endpoint:open_op(closed_error) return Op._resource(self, EndpointKind, { op = 'open', closed_error = closed_error }) end
function Endpoint:closed_op() return Op._resource(self, EndpointKind, { op = 'closed' }) end
function Endpoint:terminal_op(default_error) return Op._resource(self, EndpointKind, { op = 'terminal', default_error = default_error }) end
function Endpoint:error_op() return Op._resource(self, EndpointKind, { op = 'error' }) end
function Endpoint:close_op(reason) return Op._resource(self, EndpointKind, { op = 'close', reason = reason }) end
function Endpoint:shutdown_op(reason) return Op._resource(self, EndpointKind, { op = 'shutdown', reason = reason }) end
function Endpoint:fail_op(err) return Op._resource(self, EndpointKind, { op = 'fail', error = err or Errors.FLOW_ERROR }) end
function Endpoint:changed_op(version) return Op._resource(self, EndpointKind, { op = 'changed', version = version }) end

Endpoint.Kind = EndpointKind
return Endpoint
