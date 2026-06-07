-- Region: public lifetime and ownership boundary.

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

function RegionKind.clone(rec)
  return { kind = RegionKind, read = rec.read, close = rec.close, add = copy_map(rec.add), remove = copy_map(rec.remove) }
end

function RegionKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.close then dst.close = true end
  for item, v in pairs(src.add or {}) do dst.add = dst.add or {}; dst.add[item] = v; if dst.remove then dst.remove[item] = nil end end
  for item, v in pairs(src.remove or {}) do dst.remove = dst.remove or {}; dst.remove[item] = v; if dst.add then dst.add[item] = nil end end
  return true
end

function RegionKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.close then dst.close = true end
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
  if query == 'closed' then return region.closed or (rec and rec.close) or false, true end
  return nil, false
end

function RegionKind.prepare(region, rec, _resolve)
  if rec.read ~= nil and (region.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.close and not next(rec.add or {}) and not next(rec.remove or {}) then return nil, nil, true end
  local consequence_set = ConsequenceSet.empty()
  local ok, err = consequence_set:add(Effect.wake('region', region._fibers_id, { region = region, close = rec.close }))
  if not ok then return nil, err end
  return { kind = RegionKind, resource = region, close = rec.close, add = copy_map(rec.add), remove = copy_map(rec.remove), consequence_set = consequence_set }
end

function RegionKind.apply(prepared, _log)
  local region = prepared.resource
  for item in pairs(prepared.remove or {}) do region.owned[item] = nil end
  for item in pairs(prepared.add or {}) do region.owned[item] = true end
  if prepared.close then region.closed = true end
  region.version = (region.version or 0) + 1
end

local function admit_candidate(region, item, expected_owner, ctx)
  if Resource.project(ctx, region, 'closed') then return nil end
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= nil and current_owner ~= expected_owner then return nil end
  local c = Candidate.new(OpPack(item))
  local rrec = read_region(c, region)
  rrec.add[item] = true
  set_owner(c, item, region)
  return c
end

local function release_candidate(region, item, ctx)
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  local c = Candidate.new(OpPack(item))
  local rrec = read_region(c, region)
  rrec.remove[item] = true
  set_owner(c, item, nil)
  return c
end

function RegionKind.eval(region, payload, ctx)
  local op = payload.op
  if op == 'admit' then
    local c = admit_candidate(region, payload.item, payload.from_owner, ctx)
    if not c then return Result.none() end
    return Result.cands({ c })
  elseif op == 'release' then
    local c = release_candidate(region, payload.item, ctx)
    if not c then return Result.none() end
    return Result.cands({ c })
  elseif op == 'close' then
    if Resource.project(ctx, region, 'closed') then return Result.none() end
    local c = Candidate.new(OpPack(true))
    local rec = read_region(c, region)
    rec.close = true
    return Result.cands({ c })
  elseif op == 'is_open' then
    local c = Candidate.new(OpPack(not Resource.project(ctx, region, 'closed')))
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

function Region.new(name)
  next_id = next_id + 1
  local id = 'region-' .. tostring(next_id)
  return setmetatable({ name = name or id, owned = {}, closed = false, version = 0, _fibers_id = id, _fibers_kind = RegionKind, _fibers_value = true }, Region)
end

function Region:admit_op(a, b, c)
  local Op, item, from_owner
  if is_op_module(a) then Op, item, from_owner = a, b, c else Op, item, from_owner = DefaultOp, a, b end
  return Op._resource(self, RegionKind, { op = 'admit', item = item, from_owner = from_owner })
end

function Region:release_op(a, b)
  local Op, item
  if is_op_module(a) then Op, item = a, b else Op, item = DefaultOp, a end
  return Op._resource(self, RegionKind, { op = 'release', item = item })
end

function Region:transfer_op(a, b, c)
  local Op, item, to_region
  if is_op_module(a) then Op, item, to_region = a, b, c else Op, item, to_region = DefaultOp, a, b end
  return self:release_op(Op, item):and_then(function()
    return to_region:admit_op(Op, item, self)
  end)
end

function Region:close_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, RegionKind, { op = 'close' })
end

function Region:is_open_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, RegionKind, { op = 'is_open' })
end

function Region:spawn_op(a, b, c)
  local Op, fn, name
  if is_op_module(a) then Op, fn, name = a, b, c else Op, fn, name = DefaultOp, a, b end
  local Task = require('fibers.task')
  local task = Task.new(fn, name)
  return self:admit_op(Op, task):and_then(function()
    return Op.emit(task:_spawn_effect()):map(function() return task end)
  end)
end

Region.Kind = RegionKind
return Region
