-- Region: public transactional ownership and claim boundary.
--
-- A Region owns typed ownership records, not bare objects.  Each admitted item is
-- admitted with a settlement protocol; compound admissions install a tree of
-- ownership records.  Facilities can then claim owned subtrees for a purpose and
-- settle those claims without Region knowing policy-specific words such as
-- shutdown, migration or item settlement.

local DefaultOp = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local KernelResources = require('fibers.kernel.resources')
local Validity = require('fibers.kernel.validity')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local EffectSet = require('fibers.kernel.effect.set')
local Effect = require('fibers.base.effect')
local Ownership = require('fibers.internal.ownership')
local Settlement = require('fibers.internal.settlement')
local Claim = require('fibers.internal.claim')
local OpPack = DefaultOp._pack

local Region = {}
Region.__index = Region

local RegionKind = { name = 'region' }
local next_id = 0

-- Advanced Region ownership admission specifications.
--
-- Owned is intentionally part of Region's vocabulary, not an eighth base noun.
-- Ordinary users should normally receive Owned values from resource/facility
-- constructors.  Resource authors use Region.Owned to attach settlement
-- protocols and child ownership trees to values admitted to a Region.
local Owned = {}

local function copy_owned_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function as_settlement_protocol(settle, label)
  if settle == nil then return Settlement.none() end
  if type(settle) ~= 'function' then error((label or 'settlement protocol') .. ' must be a function', 3) end
  return settle
end

local function owned_spec(item, settle, children, opts)
  if item == nil then error('Region.Owned.item expects an item', 3) end
  opts = opts or {}
  return {
    _fibers_owned_spec = true,
    _fibers_value = true,
    item = item,
    settle = as_settlement_protocol(settle, 'Region.Owned.item settle'),
    settle_name = opts.settle_name,
    role = opts.role,
    meta = opts.meta,
    children = copy_owned_list(children),
  }
end

function Owned.item(item, settle, opts)
  return owned_spec(item, settle, nil, opts)
end

function Owned.tree(item, settle, children, opts)
  return owned_spec(item, settle, children or {}, opts)
end

function Owned.inert(item, opts)
  opts = opts or {}
  opts.settle_name = opts.settle_name or 'none'
  return Owned.item(item, Settlement.none(), opts)
end

function Owned.is(x)
  return type(x) == 'table' and x._fibers_owned_spec == true
end

function Owned.from_item(item, opts)
  if Owned.is(item) then return item end
  if type(item) ~= 'table' then error('owned admission expects a Region.Owned value or owned handle', 3) end
  local f = item._fibers_settle
  if type(f) ~= 'function' then
    error('owned admission requires a settlement protocol; use Region.Owned.item(...) or a handle constructor', 3)
  end
  opts = opts or { role = item._fibers_obligation_kind or item._fibers_kind_name, settle_name = item._fibers_settle_name }
  return Owned.item(item, f, opts)
end

local function copy_list(src)
  local out = {}
  for i = 1, #(src or {}) do out[i] = src[i] end
  return out
end

local function copy_record_internal(r)
  if not r then return nil end
  return {
    _fibers_value = true,
    item = r.item,
    settle = r.settle,
    settle_name = r.settle_name,
    role = r.role,
    parent = r.parent,
    children = copy_list(r.children),
    phase = r.phase or 'live',
    claim = r.claim,
    claim_id = r.claim_id,
    claim_purpose = r.claim_purpose,
    claim_reason = r.claim_reason,
    settlement_error = r.settlement_error,
    settlement_error_message = r.settlement_error_message,
    settlement_failed = r.settlement_failed,
    meta = r.meta,
  }
end

local function copy_record_public(r)
  local out = copy_record_internal(r)
  if out then out.claim = nil end
  return out
end

local function copy_map(src)
  local out = {}
  if src then for k, v in pairs(src) do out[k] = copy_record_internal(v) or v end end
  return out
end

local function projected_owned(region, rec)
  local map = copy_map(region.owned)
  if rec then
    for item in pairs(rec.remove or {}) do map[item] = nil end
    for item, record in pairs(rec.add or {}) do map[item] = copy_record_internal(record) end
  end
  return map
end

local function sorted_owned(region, rec)
  local map = projected_owned(region, rec)
  local out = {}
  for item in pairs(map) do out[#out + 1] = item end
  table.sort(out, function(a, b)
    local ak = tostring((type(a) == 'table' and (a._fibers_id or a.name)) or a)
    local bk = tostring((type(b) == 'table' and (b._fibers_id or b.name)) or b)
    return ak < bk
  end)
  return out
end

local function projected_count(region, rec)
  local n = 0
  for _ in pairs(projected_owned(region, rec)) do n = n + 1 end
  return n
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

local function record_for(ctx, region, item)
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[region]
  local map = projected_owned(region, rec)
  return map[item]
end

local function spec_to_records(spec, parent, out)
  spec = Owned.from_item(spec)
  out = out or {}
  local item = spec.item
  if out[item] then error('Owned tree contains duplicate item', 3) end
  local record = {
    _fibers_value = true,
    item = item,
    settle = spec.settle,
    settle_name = spec.settle_name,
    role = spec.role or (type(item) == 'table' and (item._fibers_obligation_kind or item._fibers_kind_name)) or nil,
    parent = parent,
    children = {},
    phase = 'live',
    claim = nil,
    claim_id = nil,
    claim_purpose = nil,
    claim_reason = nil,
    meta = spec.meta,
  }
  out[item] = record
  for i = 1, #(spec.children or {}) do
    local child = Owned.from_item(spec.children[i])
    record.children[#record.children + 1] = child.item
    spec_to_records(child, item, out)
  end
  return out, item
end

local function collect_subtree_from_map(map, item, out)
  out = out or {}
  local record = map[item]
  if not record then return out end
  out[item] = copy_record_internal(record)
  for i = 1, #(record.children or {}) do collect_subtree_from_map(map, record.children[i], out) end
  return out
end

local function collect_subtree_list_from_map(map, item, out)
  out = out or {}
  local record = map[item]
  if not record then return out end
  out[#out + 1] = copy_record_internal(record)
  for i = 1, #(record.children or {}) do collect_subtree_list_from_map(map, record.children[i], out) end
  return out
end

local function collect_subtree_list_public_from_map(map, item, out)
  out = out or {}
  local record = map[item]
  if not record then return out end
  out[#out + 1] = copy_record_public(record)
  for i = 1, #(record.children or {}) do collect_subtree_list_public_from_map(map, record.children[i], out) end
  return out
end

local function any_claimed(subtree)
  for _, record in pairs(subtree or {}) do
    local phase = record.phase or 'live'
    if phase == 'claimed' or phase == 'settlement_failed' then return true end
  end
  return false
end

local function read_only_candidate(region, value)
  local c = Proposal.new(OpPack(value))
  read_region(c, region)
  return c
end

local function has_owned_children_after(region, rec, item)
  local map = projected_owned(region, rec)
  local record = map[item]
  if not record then return false end
  for i = 1, #(record.children or {}) do if map[record.children[i]] then return true end end
  return false
end

function RegionKind.clone(rec)
  return { kind = RegionKind, read = rec.read, seal = rec.seal, add = copy_map(rec.add), remove = copy_map(rec.remove) }
end

function RegionKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.seal then dst.seal = true end
  dst.add = dst.add or {}; dst.remove = dst.remove or {}
  for item, record in pairs(src.add or {}) do dst.add[item] = copy_record_internal(record); dst.remove[item] = nil end
  for item, record in pairs(src.remove or {}) do dst.remove[item] = copy_record_internal(record) or true; dst.add[item] = nil end
  return true
end

function RegionKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.seal then dst.seal = true end
  dst.add = dst.add or {}; dst.remove = dst.remove or {}
  for item, record in pairs(src.add or {}) do
    if dst.remove[item] then return false, 'region-add-remove-conflict' end
    if dst.add[item] then return false, 'region-add-conflict' end
    dst.add[item] = copy_record_internal(record)
  end
  for item, record in pairs(src.remove or {}) do
    if dst.add[item] then return false, 'region-add-remove-conflict' end
    dst.remove[item] = copy_record_internal(record) or true
  end
  return true
end

function RegionKind.project(region, rec, query)
  if query == 'sealed' then return region.sealed or (rec and rec.seal) or false, true end
  if query == 'open' then return not (region.sealed or (rec and rec.seal) or false), true end
  if query == 'snapshot' then
    local sealed = region.sealed or (rec and rec.seal) or false
    return { sealed = sealed, open = not sealed, owned_count = projected_count(region, rec) }, true
  elseif query == 'members' then
    return sorted_owned(region, rec), true
  elseif type(query) == 'table' and query.op == 'record' then
    local map = projected_owned(region, rec)
    return copy_record_public(map[query.item]), true
  elseif type(query) == 'table' and query.op == 'children' then
    local map = projected_owned(region, rec)
    local r = map[query.item]
    return r and copy_list(r.children) or nil, true
  elseif type(query) == 'table' and query.op == 'subtree' then
    local map = projected_owned(region, rec)
    if not map[query.item] then return nil, true end
    return collect_subtree_list_public_from_map(map, query.item), true
  end
  return nil, false
end

function RegionKind.prepare(region, rec, _resolve)
  if rec.read ~= nil and (region.version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.seal and not next(rec.add or {}) and not next(rec.remove or {}) then return nil, nil, true end
  local effect_set = EffectSet.empty()
  local ok, err = effect_set:add(Effect.wake('region', region._fibers_id, { region = region, sealed = rec.seal }))
  if not ok then return nil, err end
  return { kind = RegionKind, resource = region, seal = rec.seal, add = copy_map(rec.add), remove = copy_map(rec.remove), effect_set = effect_set }
end

function RegionKind.apply(prepared, _log)
  local region = prepared.resource
  for item in pairs(prepared.remove or {}) do
    if region.owned[item] then region.owned[item] = nil end
  end
  for item, record in pairs(prepared.add or {}) do
    region.owned[item] = copy_record_internal(record)
  end
  local n = 0; for _ in pairs(region.owned) do n = n + 1 end
  region.owned_count = n
  if prepared.seal then region.sealed = true end
  region.version = (region.version or 0) + 1
  KernelResources.invalidate_object(region, 'region membership changed')
end

local function admit_candidate(region, owned_spec, expected_owner, ctx)
  if is_sealed(ctx, region) then return nil end
  local records, root = spec_to_records(owned_spec)
  local c = Proposal.new(OpPack(root))
  local rrec = read_region(c, region)
  for item, record in pairs(records) do
    local current_owner = Resource.project(ctx, item, 'owner')
    if current_owner ~= nil and current_owner ~= expected_owner then return nil end
    if record.parent ~= nil and not records[record.parent] then return nil end
    rrec.add[item] = copy_record_internal(record)
    rrec.remove[item] = nil
    set_owner(c, item, region)
  end
  return c
end

local function release_candidate(region, item, ctx)
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  local c = Proposal.new(OpPack(item))
  local rrec = read_region(c, region)
  local record = record_for(ctx, region, item)
  if not record then return nil end
  if record.parent ~= nil then return nil end
  if (record.phase or 'live') ~= 'live' then return nil end
  rrec.remove[item] = copy_record_internal(record)
  local current_map = projected_owned(region, nil)
  for i = 1, #(record.children or {}) do
    local child = record.children[i]
    if current_map[child] and not rrec.remove[child] then return nil end
  end
  set_owner(c, item, nil)
  return c
end

local function claim_candidate(region, item, purpose, ctx)
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[region]
  local map = projected_owned(region, rec)
  local root_record = map[item]
  if not root_record then return nil end
  if root_record.parent ~= nil then return nil end
  local subtree = collect_subtree_from_map(map, item)
  if any_claimed(subtree) then return nil end
  local records = collect_subtree_list_from_map(map, item)
  local claim = Claim.new(region, item, records, purpose)
  local c = Proposal.new(OpPack(claim))
  local rrec = read_region(c, region)
  for child, record in pairs(subtree) do
    local updated = copy_record_internal(record)
    updated.phase = 'claimed'
    updated.claim = claim
    updated.claim_id = claim.id
    updated.claim_purpose = purpose
    updated.claim_reason = type(purpose) == 'table' and purpose.reason or nil
    rrec.add[child] = updated
    rrec.remove[child] = nil
    read_owned(c, child)
  end
  return c
end

local function settle_claim_candidate(region, claim, ctx)
  if not Claim.is(claim) then return nil end
  if claim.region ~= region then return nil end
  local item = claim.root
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[region]
  local map = projected_owned(region, rec)
  local root_record = map[item]
  if not root_record then return nil end
  if root_record.parent ~= nil then return nil end
  if root_record.claim ~= claim then return nil end
  local subtree = collect_subtree_from_map(map, item)
  if not next(subtree) then return nil end
  local expected = {}
  for i = 1, #(claim.records or {}) do expected[claim.records[i].item] = true end
  for child, record in pairs(subtree) do
    if not expected[child] then return nil end
    if (record.phase or 'live') ~= 'claimed' then return nil end
    if record.claim ~= claim then return nil end
  end
  local c = Proposal.new(OpPack(item))
  local rrec = read_region(c, region)
  for child, record in pairs(subtree) do
    rrec.remove[child] = copy_record_internal(record)
    rrec.add[child] = nil
    set_owner(c, child, nil)
  end
  return c
end


local function settlement_failure_candidate(region, claim, failure, ctx)
  if not Claim.is(claim) then return nil end
  if claim.region ~= region then return nil end
  local item = claim.root
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[region]
  local map = projected_owned(region, rec)
  local root_record = map[item]
  if not root_record then return nil end
  if root_record.parent ~= nil then return nil end
  if root_record.claim ~= claim then return nil end
  local subtree = collect_subtree_from_map(map, item)
  if not next(subtree) then return nil end
  local message = tostring(failure)
  local c = Proposal.new(OpPack(item, failure))
  local rrec = read_region(c, region)
  for child, record in pairs(subtree) do
    if record.claim ~= claim then return nil end
    local phase = record.phase or 'live'
    if phase ~= 'claimed' and phase ~= 'settlement_failed' then return nil end
    local updated = copy_record_internal(record)
    updated.phase = 'settlement_failed'
    updated.settlement_failed = true
    updated.settlement_error = failure
    updated.settlement_error_message = message
    rrec.add[child] = updated
    rrec.remove[child] = nil
    read_owned(c, child)
  end
  return c
end

local function reassign_candidate(region, item, to_region, ctx)
  if not to_region or to_region._fibers_kind ~= RegionKind then return nil end
  local current_owner = Resource.project(ctx, item, 'owner')
  if current_owner ~= region then return nil end
  if to_region == region then return read_only_candidate(region, item) end
  if is_sealed(ctx, to_region) then return nil end

  local map = projected_owned(region, (ctx and ctx.overlay and ctx.overlay.res and ctx.overlay.res[region]) or nil)
  local root_record = map[item]
  if not root_record then return nil end
  if root_record.parent ~= nil then return nil end
  local subtree = collect_subtree_from_map(map, item)
  if any_claimed(subtree) then return nil end

  local c = Proposal.new(OpPack(item))
  local from_rec = read_region(c, region)
  local to_rec = read_region(c, to_region)
  for child, record in pairs(subtree) do
    from_rec.remove[child] = copy_record_internal(record)
    to_rec.add[child] = copy_record_internal(record)
    set_owner(c, child, to_region)
  end
  return c
end

function RegionKind.eval(region, payload, ctx)
  local op = payload.op
  if op == 'admit' then
    local c = admit_candidate(region, payload.owned or payload.item, payload.from_owner, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'release' then
    local c = release_candidate(region, payload.item, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'claim' then
    local c = claim_candidate(region, payload.item, payload.purpose, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'settle_claim' then
    local c = settle_claim_candidate(region, payload.claim, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'settlement_failed' then
    local c = settlement_failure_candidate(region, payload.claim, payload.error, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'reassign' then
    local c = reassign_candidate(region, payload.item, payload.to_region, ctx)
    if not c then return Result.none() end
    return Result.ready(c)
  elseif op == 'seal' then
    if is_sealed(ctx, region) then return Result.none() end
    local c = Proposal.new(OpPack(true))
    local rec = read_region(c, region)
    rec.seal = true
    return Result.ready(c)
  elseif op == 'is_open' then
    local c = Proposal.new(OpPack(not is_sealed(ctx, region)))
    read_region(c, region)
    return Result.ready(c)
  elseif op == 'owns' then
    local c = Proposal.new(OpPack(Resource.project(ctx, payload.item, 'owner') == region))
    read_region(c, region); read_owned(c, payload.item)
    return Result.ready(c)
  elseif op == 'record' then
    local c = Proposal.new(OpPack(Resource.project(ctx, region, { op = 'record', item = payload.item })))
    read_region(c, region)
    if payload.item then read_owned(c, payload.item) end
    return Result.ready(c)
  elseif op == 'children' then
    local c = Proposal.new(OpPack(Resource.project(ctx, region, { op = 'children', item = payload.item }) or {}))
    read_region(c, region)
    return Result.ready(c)
  elseif op == 'subtree' then
    local c = Proposal.new(OpPack(Resource.project(ctx, region, { op = 'subtree', item = payload.item }) or {}))
    read_region(c, region)
    return Result.ready(c)
  elseif op == 'snapshot' then
    local c = Proposal.new(OpPack(Resource.project(ctx, region, 'snapshot')))
    read_region(c, region)
    return Result.ready(c)
  elseif op == 'members' then
    local owned = Resource.project(ctx, region, 'members') or {}
    local c = Proposal.new(OpPack(owned))
    read_region(c, region)
    return Result.ready(c)
  end
  error('unknown region command ' .. tostring(op), 2)
end


local function observe_payload_item(ctx, item, label)
  if item ~= nil and type(ctx.observe_version) == 'function' then ctx:observe_version(item, label) end
end

function RegionKind.absence(region, payload, ctx)
  -- Region absence depends on both the region membership version and the
  -- relevant owner-bearing handle version.  This guards fallbacks against
  -- concurrent admission, release, claim settlement, and reassignment.
  ctx:observe_version(region, 'region')
  local op = payload and payload.op
  if op == 'admit' then
    local owned = payload.owned or payload.item
    observe_payload_item(ctx, owned and owned.item or owned, 'owned-item')
    observe_payload_item(ctx, payload.from_owner, 'from-owner')
  elseif op == 'settle_claim' or op == 'settlement_failed' then
    local claim = payload.claim
    observe_payload_item(ctx, claim and claim.root, 'claim-root')
    observe_payload_item(ctx, claim and claim.region, 'claim-region')
  elseif op == 'reassign' then
    observe_payload_item(ctx, payload.item, 'item')
    observe_payload_item(ctx, payload.to_region, 'target-region')
  else
    observe_payload_item(ctx, payload and payload.item, 'item')
  end
  return true
end

function RegionKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

function Region.handle(name, fields) return Ownership.handle(name, fields) end
function Region.owned(item, settle, opts) return Owned.item(item, settle, opts) end
function Region.inert(item, opts) return Owned.inert(item, opts) end

function Region.new(name)
  next_id = next_id + 1
  local id = 'region-' .. tostring(next_id)
  local region = setmetatable({ name = name or id, owned = {}, owned_count = 0, sealed = false, version = 0, _fibers_id = id, _fibers_kind = RegionKind }, Region)
  region._validity_opaque = Validity.epoch((region.name or id) .. ':membership')
  return region
end

function Region:admit_op(item_or_owned, from_owner)
  local owned = Owned.from_item(item_or_owned)
  return DefaultOp._resource(self, RegionKind, { op = 'admit', owned = owned, from_owner = from_owner })
end
function Region:release_op(item) return DefaultOp._resource(self, RegionKind, { op = 'release', item = item }) end
function Region:claim_op(item, purpose) return DefaultOp._resource(self, RegionKind, { op = 'claim', item = item, purpose = purpose }) end
function Region:settle_claim_op(claim) return DefaultOp._resource(self, RegionKind, { op = 'settle_claim', claim = claim }) end
function Region:settlement_failed_op(claim, err) return DefaultOp._resource(self, RegionKind, { op = 'settlement_failed', claim = claim, error = err }) end
function Region:reassign_op(item, to_region) return DefaultOp._resource(self, RegionKind, { op = 'reassign', item = item, to_region = to_region }) end
function Region:seal_op() return DefaultOp._resource(self, RegionKind, { op = 'seal' }) end
function Region:is_open_op() return DefaultOp._resource(self, RegionKind, { op = 'is_open' }) end
function Region:owns_op(item) return DefaultOp._resource(self, RegionKind, { op = 'owns', item = item }) end
function Region:record_op(item) return DefaultOp._resource(self, RegionKind, { op = 'record', item = item }) end
function Region:children_op(item) return DefaultOp._resource(self, RegionKind, { op = 'children', item = item }) end
function Region:subtree_op(item) return DefaultOp._resource(self, RegionKind, { op = 'subtree', item = item }) end
function Region:snapshot_op() return DefaultOp._resource(self, RegionKind, { op = 'snapshot' }) end
function Region:members_op() return DefaultOp._resource(self, RegionKind, { op = 'members' }) end

Region.Kind = RegionKind
Region.Owned = Owned
return Region
