-- Region: public transactional ownership and admission boundary.
--
-- A Region is deliberately generic.  It does not mean "task scope" and it does
-- not own a supervision policy.  It admits owned handles, transfers ownership,
-- seals future admission, and settles handles whose own kind says they are ready.

local DefaultOp = require('fibers.op')
local Resource = require('fibers.resources.protocol')
local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')
local ConsequenceSet = require('fibers.consequence.set')
local Effect = require('fibers.effect')
local Ownership = require('fibers.internal.ownership')
local OpPack = DefaultOp._pack

local Region = {}
Region.__index = Region

local RegionKind = { name = 'region' }
local next_id = 0

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
end

local function copy_map(src)
  local out = {}
  if src then for k, v in pairs(src) do out[k] = v end end
  return out
end

local function read_region(c, region)
  local rec = Resource.ensure(c, region, RegionKind)
  rec.read = rec.read or (region.version or 0)
  rec.add = rec.add or {}
  rec.remove = rec.remove or {}
  return rec
end

local function read_owned(c, item)
  local rec = Resource.ensure(c, item, Ownership.Kind)
  rec.read = rec.read or (item.owner_version or 0)
  return rec
end

local function set_owner(c, item, owner)
  local rec = read_owned(c, item)
  rec.owner_set = true
  rec.owner = owner
  return rec
end

local function is_sealed(ctx, region)
  return Resource.project(ctx, region, 'sealed') or false
end

local function can_settle(item, ctx, owner)
  local f = item and item._fibers_can_settle
  if f then return f(item, ctx, owner) end
  return true
end

function RegionKind.clone(rec)
  return {
    kind = RegionKind,
    read = rec.read,
    seal = rec.seal,
    add = copy_map(rec.add),
    remove = copy_map(rec.remove),
  }
end

function RegionKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.seal then dst.seal = true end
  for item, v in pairs(src.add or {}) do dst.add = dst.add or {}; dst.add[item] = v; if dst.remove then dst.remove[item] = nil end end
  for item, v in pairs(src.remove or {}) do dst.remove = dst.remove or {}; dst.remove[item] = v; if dst.add then dst.add[item] = nil end end
  return true
end

function RegionKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.seal then dst.seal = true end
  for item, v in pairs(src.add or {}) do
    if dst.remove and dst.remove[item] then return false, 'region-add-remove-conflict' end
    dst.add = dst.add or {}; dst.add[item] = v
  end
  for item, v in pairs(src.remove or {}) do
    if dst.add and dst.add[item] then return false, 'region-add-remove-conflict' end
    dst.remove = dst.remove or {}; dst.remove[item] = v
  end
  return true
end

function RegionKind.project(region, rec, query)
  if query == 'sealed' then return region.sealed or (rec and rec.seal) or false, true end
  if query == 'open' then return not (region.sealed or (rec and rec.seal) or false), true end
  if query == 'status' then
    local sealed = region.sealed or (rec and rec.seal) or false
    return { sealed = sealed, open = not sealed, owned_count = region.owned_count or 0, _fibers_value = true }, true
  end
  return nil, false
end

function RegionKind.prepare(region, rec, _resolve)
  if rec.read ~= nil and (region.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.seal and not next(rec.add or {}) and not next(rec.remove or {}) then return nil, nil, true end
  local consequence_set = ConsequenceSet.empty()
  local ok, err = consequence_set:add(Effect.wake('region', region._fibers_id, { region = region, sealed = rec.seal }))
  if not ok then return nil, err end
  return { kind = RegionKind, resource = region, seal = rec.seal, add = copy_map(rec.add), remove = copy_map(rec.remove), consequence_set = consequence_set }
end

function RegionKind.apply(prepared, _log)
  local region = prepared.resource
  for item in pairs(prepared.remove or {}) do
    if region.owned[item] then
      region.owned[item] = nil
      region.owned_count = math.max(0, (region.owned_count or 1) - 1)
    end
  end
  for item in pairs(prepared.add or {}) do
    if not region.owned[item] then
      region.owned[item] = true
      region.owned_count = (region.owned_count or 0) + 1
    end
  end
  if prepared.seal then
    region.sealed = true
  end
  region.version = (region.version or 0) + 1
end

local function read_only_candidate(region, value)
  local c = Candidate.new(OpPack(value))
  read_region(c, region)
  return c
end

local function admit_candidate(region, item, expected_owner, ctx)
  if is_sealed(ctx, region) then return nil end
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= nil and current_owner ~= expected_owner then return nil end
  local c = Candidate.new(OpPack(item))
  local rrec = read_region(c, region)
  rrec.add[item] = true
  set_owner(c, item, region)
  return c
end

local function settle_candidate(region, item, ctx)
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  if not can_settle(item, ctx, region) then return nil end
  local c = Candidate.new(OpPack(item))
  local rrec = read_region(c, region)
  rrec.remove[item] = true
  set_owner(c, item, nil)
  return c
end

local function transfer_candidate(region, item, to_region, ctx)
  if not to_region or to_region._fibers_kind ~= RegionKind then return nil end
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  if to_region == region then return read_only_candidate(region, item) end
  if is_sealed(ctx, to_region) then return nil end

  local c = Candidate.new(OpPack(item))
  local from_rec = read_region(c, region)
  from_rec.remove[item] = true
  local to_rec = read_region(c, to_region)
  to_rec.add[item] = true
  set_owner(c, item, to_region)
  return c
end

function RegionKind.eval(region, payload, ctx)
  local op = payload.op
  if op == 'admit' then
    local c = admit_candidate(region, payload.item, payload.from_owner, ctx)
    if not c then return Result.none() end
    return Result.cands({ c })
  elseif op == 'settle' then
    local c = settle_candidate(region, payload.item, ctx)
    if not c then return Result.none() end
    return Result.cands({ c })
  elseif op == 'transfer' then
    local c = transfer_candidate(region, payload.item, payload.to_region, ctx)
    if not c then return Result.none() end
    return Result.cands({ c })
  elseif op == 'seal' then
    if is_sealed(ctx, region) then return Result.none() end
    local c = Candidate.new(OpPack(true))
    local rec = read_region(c, region)
    rec.seal = true
    return Result.cands({ c })
  elseif op == 'is_open' then
    local c = Candidate.new(OpPack(not is_sealed(ctx, region)))
    read_region(c, region)
    return Result.cands({ c })
  elseif op == 'owns' then
    local c = Candidate.new(OpPack(Resource.project(ctx, payload.item, 'owner') == region))
    read_region(c, region)
    read_owned(c, payload.item)
    return Result.cands({ c })
  elseif op == 'status' then
    local c = Candidate.new(OpPack(Resource.project(ctx, region, 'status')))
    read_region(c, region)
    return Result.cands({ c })
  end
  error('unknown region operation ' .. tostring(op), 2)
end

function RegionKind.summary(_payload, out)
  out.resources = true
  out.dynamic = true
  out.closed = false
end


function Region.handle(name, fields)
  return Ownership.handle(name, fields)
end

function Region.new(name)
  next_id = next_id + 1
  local id = 'region-' .. tostring(next_id)
  return setmetatable({
    name = name or id,
    owned = {},
    owned_count = 0,
    sealed = false,
    version = 0,
    _fibers_id = id,
    _fibers_kind = RegionKind,
    _fibers_value = true,
  }, Region)
end

function Region:admit_op(a, b, c)
  local Op, item, from_owner
  if is_op_module(a) then Op, item, from_owner = a, b, c else Op, item, from_owner = DefaultOp, a, b end
  return Op._resource(self, RegionKind, { op = 'admit', item = item, from_owner = from_owner })
end

function Region:settle_op(a, b)
  local Op, item
  if is_op_module(a) then Op, item = a, b else Op, item = DefaultOp, a end
  return Op._resource(self, RegionKind, { op = 'settle', item = item })
end
function Region:transfer_op(a, b, c)
  local Op, item, to_region
  if is_op_module(a) then Op, item, to_region = a, b, c else Op, item, to_region = DefaultOp, a, b end
  return Op._resource(self, RegionKind, { op = 'transfer', item = item, to_region = to_region })
end

function Region:seal_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, RegionKind, { op = 'seal' })
end
function Region:is_open_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, RegionKind, { op = 'is_open' })
end

function Region:owns_op(a, b)
  local Op, item
  if is_op_module(a) then Op, item = a, b else Op, item = DefaultOp, a end
  return Op._resource(self, RegionKind, { op = 'owns', item = item })
end

function Region:cancel_op(a, b, c)
  local Op, item, reason
  if is_op_module(a) then Op, item, reason = a, b, c else Op, item, reason = DefaultOp, a, b end
  if not item or type(item.cancel_op) ~= 'function' then return Op.never() end
  return self:owns_op(Op, item):and_then(function(owns)
    if not owns then return Op.never() end
    return item:cancel_op(Op, reason)
  end)
end

function Region:status_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, RegionKind, { op = 'status' })
end
Region.Kind = RegionKind
return Region
