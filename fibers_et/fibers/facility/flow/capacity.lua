-- Transactional byte capacity for Flow.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')
local OpPack = Op._pack

local Capacity = {}
Capacity.__index = Capacity
local CapacityKind = { name = 'flow_capacity' }
local next_id = 0
local INF = math.huge

local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then error((label or 'Flow capacity count') .. ' must be a non-negative integer', 3) end
  return n
end

local function ensure_record(c, cap, version)
  local rec = Resource.ensure(c, cap, CapacityKind)
  rec.read = rec.read or (version or cap.version or 0)
  rec.delta = rec.delta or 0
  return rec
end

local function available(cap, rec)
  if cap.limit == nil then return INF end
  local n = (cap.available or 0) + ((rec and rec.delta) or 0)
  if n < 0 then return 0 end
  if n > cap.limit then return cap.limit end
  return n
end

local function state_table(cap, rec)
  local a = available(cap, rec)
  return { capacity = cap, limit = cap.limit, available = a, free = a, used = cap.limit and (cap.limit - a) or 0, version = cap.version or 0 }
end

local function read_only(cap, version, ...)
  local c = Candidate.new(OpPack(...))
  ensure_record(c, cap, version)
  return c
end

local function wake_set(cap)
  return Versioned.wake_set('flow:capacity:changed', cap._fibers_id, { capacity = cap })
end

function CapacityKind.clone(rec) return { kind = CapacityKind, read = rec.read, delta = rec.delta or 0 } end
function CapacityKind.merge_seq(dst, src) if src.read ~= nil and dst.read == nil then dst.read = src.read end; dst.delta = (dst.delta or 0) + (src.delta or 0); return true end
function CapacityKind.merge_par(dst, src) if src.read ~= nil and dst.read == nil then dst.read = src.read end; dst.delta = (dst.delta or 0) + (src.delta or 0); return true end

function CapacityKind.project(cap, rec, query)
  if query == 'available' or query == 'free' then return available(cap, rec), true end
  if query == 'state' or query == 'snapshot' then return state_table(cap, rec), true end
  return nil, false
end

function CapacityKind.prepare(cap, rec, _resolve)
  if rec.read ~= nil and (cap.version or 0) ~= rec.read then return nil, 'stale' end
  local delta = rec.delta or 0
  if delta == 0 then return nil, nil, true end
  if cap.limit ~= nil then
    local final = (cap.available or 0) + delta
    if final < 0 then return nil, Errors.CAPACITY end
    if final > cap.limit then return nil, Errors.CAPACITY_OVER_RELEASE end
  end
  local set, err = wake_set(cap)
  if err then return nil, err end
  return { kind = CapacityKind, resource = cap, delta = delta, consequence_set = set }
end

function CapacityKind.apply(prepared, _log)
  local cap = prepared.resource
  if cap.limit ~= nil then cap.available = cap.available + prepared.delta end
  cap.version = (cap.version or 0) + 1
end

function CapacityKind.eval(cap, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, cap)
  local rec = Versioned.overlay_rec(ctx, cap)
  local free = available(cap, rec)
  if op == 'reserve' then
    local n = as_nonneg_int(payload.n, 0, 'Flow reserve size')
    if n == 0 then return Result.cands({ read_only(cap, version, 0) }) end
    if cap.limit ~= nil and n > cap.limit then return Result.cands({ read_only(cap, version, nil, Errors.TOO_LARGE) }) end
    if free >= n then
      local c = Candidate.new(OpPack(n))
      local r = ensure_record(c, cap, version); r.delta = (r.delta or 0) - n
      return Result.cands({ c })
    end
    return Result.wait(Wait.resource('flow:capacity:changed', cap._fibers_id, cap, { op = 'reserve', n = n }))
  elseif op == 'reserve_some' then
    local max = as_nonneg_int(payload.max, 1, 'Flow reserve_some size')
    if max == 0 then return Result.cands({ read_only(cap, version, 0) }) end
    if free > 0 then
      local n = cap.limit == nil and max or math.min(max, free)
      local c = Candidate.new(OpPack(n))
      local r = ensure_record(c, cap, version); r.delta = (r.delta or 0) - n
      return Result.cands({ c })
    end
    return Result.wait(Wait.resource('flow:capacity:changed', cap._fibers_id, cap, { op = 'reserve_some', max = max }))
  elseif op == 'release' then
    local n = as_nonneg_int(payload.n, 0, 'Flow release size')
    if n == 0 or cap.limit == nil then return Result.cands({ read_only(cap, version, true) }) end
    local c = Candidate.new(OpPack(true))
    local r = ensure_record(c, cap, version); r.delta = (r.delta or 0) + n
    return Result.cands({ c })
  elseif op == 'state' then
    return Result.cands({ read_only(cap, version, state_table(cap, rec)) })
  elseif op == 'changed' then
    if version ~= payload.version then return Result.cands({ read_only(cap, version, state_table(cap, rec)) }) end
    return Result.wait(Wait.resource('flow:capacity:changed', cap._fibers_id, cap, { op = 'changed', version = payload.version }))
  end
  error('unknown Flow capacity operation ' .. tostring(op), 2)
end

function CapacityKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

function Capacity.new(limit, name)
  if limit ~= nil then limit = as_nonneg_int(limit, nil, 'Flow capacity') end
  next_id = next_id + 1
  local id = 'flow-capacity-' .. tostring(next_id)
  return setmetatable({ limit = limit, available = limit or INF, version = 0, name = name or id, _fibers_id = id, _fibers_kind = CapacityKind }, Capacity)
end

function Capacity:reserve_op(n) return Op._resource(self, CapacityKind, { op = 'reserve', n = as_nonneg_int(n, 0, 'Flow reserve size') }) end
function Capacity:reserve_some_op(max) return Op._resource(self, CapacityKind, { op = 'reserve_some', max = as_nonneg_int(max, 1, 'Flow reserve_some size') }) end
function Capacity:release_op(n) return Op._resource(self, CapacityKind, { op = 'release', n = as_nonneg_int(n, 0, 'Flow release size') }) end
function Capacity:state_op() return Op._resource(self, CapacityKind, { op = 'state' }) end
function Capacity:changed_op(version) return Op._resource(self, CapacityKind, { op = 'changed', version = version }) end

Capacity.Kind = CapacityKind
return Capacity
