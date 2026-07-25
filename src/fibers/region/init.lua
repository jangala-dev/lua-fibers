-- Region and ownership over one versioned serial-transducer ledger.
--
-- The shared ledger deliberately uses coarse conflict granularity: atomic tree
-- admission, cross-region movement, claims and settlement are one guarded
-- state transition. A partitioned persistent forest can preserve these laws
-- while improving scalability.

local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local Effect = require('fibers.effect')
local Settlement = require('fibers.region.settlement')

local next_handle = 0
local OwnershipKind = { name = 'ownership' }

local function ownership_handle(name, fields)
  next_handle = next_handle + 1
  local id = 'owned-' .. tostring(next_handle)
  local h = fields or {}
  h.name = name or h.name or id
  h.owner = h.owner
  h.owner_version = h.owner_version or 0
  h._fibers_id = h._fibers_id or id
  h._fibers_kind = OwnershipKind
  h._fibers_obligation_kind = h._fibers_obligation_kind or h.kind
  h._fibers_settle = Settlement.normalize(h._fibers_settle or h.settle, 'owned handle settlement')
  h._fibers_settle_name = h._fibers_settle_name or h.settle_name or 'none'
  return h
end

local Claim = {}
local next_claim = 0

function Claim.new(region, root, records, purpose)
  next_claim = next_claim + 1
  return {
    _fibers_claim = true,
    _fibers_value = true,
    id = 'claim-' .. tostring(next_claim),
    region = region,
    root = root,
    records = records,
    purpose = purpose,
    reason = type(purpose) == 'table' and purpose.reason or nil,
    started = false,
    running = false,
    complete = false,
  }
end

function Claim.is(x)
  return type(x) == 'table' and x._fibers_claim == true
end

local Region = {}
Region.__index = Region
local Kind = { name = 'region' }
local Phase = { live = 'live', claimed = 'claimed', failed = 'failed', retired = 'retired' }
local Ready, Wait = Scalar.Ready, Scalar.Wait
local unpack_ = table.unpack or unpack
local next_region = 0

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function copy_set(xs)
  local out = {}
  for k, v in pairs(xs or {}) do
    if v then
      out[k] = true
    end
  end
  return out
end

local function copy_record(r, public)
  if not r then
    return nil
  end
  local out = {
    _fibers_value = true,
    item = r.item,
    settle = r.settle,
    settle_name = r.settle_name,
    role = r.role,
    parent = r.parent,
    children = copy_list(r.children),
    phase = r.phase,
    claim = (not public) and r.claim or nil,
    claim_id = r.claim_id,
    claim_purpose = r.claim_purpose,
    claim_reason = r.claim_reason,
    settlement_error = r.settlement_error,
    settlement_error_message = r.settlement_error_message,
    settlement_failed = r.settlement_failed,
    settlement_state = r.settlement_state,
    settlement_request_state = r.settlement_request_state,
    settlement_force_state = r.settlement_force_state,
    settlement_request_error = r.settlement_request_error,
    settlement_force_error = r.settlement_force_error,
    admission_order = r.admission_order,
    rights = r.rights,
    meta = r.meta,
  }
  return out
end

local TOMBSTONE = {}
local next_pmap_key = 0
local function pmap_key(key)
  if type(key) ~= 'table' then
    return key
  end
  local id = rawget(key, '_fibers_ledger_key')
  if id == nil then
    next_pmap_key = next_pmap_key + 1
    id = next_pmap_key
    rawset(key, '_fibers_ledger_key', id)
  end
  return id
end

local PMap = {}
PMap.__index = function(self, key)
  key = pmap_key(key)
  local delta = rawget(self, '_delta')
  local value = delta[key]
  if value ~= nil then
    if value == TOMBSTONE then
      return nil
    end
    return value
  end
  local parent = rawget(self, '_parent')
  return parent and parent[key] or nil
end
PMap.__newindex = function(self, key, value)
  rawget(self, '_delta')[pmap_key(key)] = value == nil and TOMBSTONE or value
end
local function pmap(parent)
  return setmetatable({
    _parent = parent,
    _delta = {},
    _depth = parent and ((rawget(parent, '_depth') or 0) + 1) or 0,
  }, PMap)
end
local function pmap_local(map, key)
  return rawget(map, '_delta')[pmap_key(key)] ~= nil
end

local function pmap_flatten(map)
  local flat = pmap(nil)
  local delta, seen = rawget(flat, '_delta'), {}
  local node = map
  while node do
    for key, value in pairs(rawget(node, '_delta') or {}) do
      if not seen[key] then
        seen[key] = true
        if value ~= TOMBSTONE then
          delta[key] = value
        end
      end
    end
    node = rawget(node, '_parent')
  end
  return flat
end

local function pmap_child(parent)
  if parent and (rawget(parent, '_depth') or 0) > 24 then
    return pmap(pmap_flatten(parent))
  end
  return pmap(parent)
end

local function compact_region_order(records, order)
  local seen = pmap(nil)
  local head, tail
  local node = order
  while node do
    local key = node.key
    if records[key] ~= nil and seen[key] == nil then
      seen[key] = true
      local copy = { key = key }
      if tail then
        tail.next = copy
      else
        head = copy
      end
      tail = copy
    end
    node = node.next
  end
  return head, seen
end

local function copy_region_state(rs, region)
  if not rs then
    return {
      sealed = region and region.sealed == true or false,
      version = region and region.version or 0,
      count = 0,
      next_admission = 0,
      records = pmap(nil),
      order = nil,
      seen = pmap(nil),
    }
  end
  if (rs.count or 0) == 0 then
    return {
      sealed = rs.sealed == true,
      version = rs.version or 0,
      count = 0,
      next_admission = rs.next_admission or 0,
      records = pmap(nil),
      order = nil,
      seen = pmap(nil),
    }
  end
  local compact = (rawget(rs.records, '_depth') or 0) > 24 or (rawget(rs.seen, '_depth') or 0) > 24
  if compact then
    local records = pmap_flatten(rs.records)
    local order, seen = compact_region_order(records, rs.order)
    return {
      sealed = rs.sealed == true,
      version = rs.version or 0,
      count = rs.count or 0,
      next_admission = rs.next_admission or 0,
      records = pmap(records),
      order = order,
      seen = pmap(seen),
    }
  end
  return {
    sealed = rs.sealed == true,
    version = rs.version or 0,
    count = rs.count or 0,
    next_admission = rs.next_admission or 0,
    records = pmap(rs.records),
    order = rs.order,
    seen = pmap(rs.seen),
  }
end

local function clone_ledger(s)
  return {
    regions = pmap_child(s and s.regions),
    owners = pmap_child(s and s.owners),
    region_count = s and s.region_count or 0,
    owner_count = s and s.owner_count or 0,
    dirty_regions = copy_set(s and s.dirty_regions),
    dirty_items = copy_set(s and s.dirty_items),
  }
end

local initial_ledger = {
  regions = pmap(nil),
  owners = pmap(nil),
  region_count = 0,
  owner_count = 0,
  dirty_regions = {},
  dirty_items = {},
}
local ledger = Scalar.machine(initial_ledger, 'region-ledger')
ledger._location.clone_value = nil

local function sync_projection(s, loc)
  local removed_region = false
  for region in pairs(s.dirty_regions or {}) do
    local rs = s.regions[region]
      or {
        sealed = region.sealed == true,
        version = region.version or 0,
        count = 0,
        records = pmap(nil),
      }
    region.sealed, region.version = rs.sealed == true, rs.version or 0
    if (rs.count or 0) == 0 and s.regions[region] ~= nil then
      s.regions[region] = nil
      s.region_count = math.max((s.region_count or 1) - 1, 0)
      removed_region = true
    end
  end
  for item in pairs(s.dirty_items or {}) do
    local old_owner, new_owner = item.owner, s.owners[item]
    if old_owner ~= new_owner then
      if old_owner and old_owner.owned[item] then
        old_owner.owned[item] = nil
        old_owner.owned_count = old_owner.owned_count - 1
      end
      if new_owner then
        local rec = (s.regions[new_owner] and s.regions[new_owner].records[item]) or nil
        if not new_owner.owned[item] then
          new_owner.owned_count = new_owner.owned_count + 1
        end
        new_owner.owned[item] = copy_record(rec, false)
      end
      item.owner_version = (item.owner_version or 0) + 1
    elseif new_owner then
      new_owner.owned[item] = copy_record(s.regions[new_owner] and s.regions[new_owner].records[item], false)
    end
    item.owner = new_owner
    item._fibers_retired = new_owner == nil and item.owner_version > 0 or false
  end
  if (s.owner_count or 0) == 0 then
    s.owners = pmap(nil)
  end
  if (s.region_count or 0) == 0 then
    s.regions = pmap(nil)
  elseif removed_region then
    -- A tombstone shadows an old region state semantically but the persistent
    -- parent would still retain that state physically. Flatten on retirement.
    s.regions = pmap_flatten(s.regions)
  end
  s.dirty_regions, s.dirty_items = {}, {}
end

ledger._location.apply = function(v, loc)
  ledger.value = v
  ledger.version = loc.version
  sync_projection(v, loc)
end

local function event_of(event)
  return Effect.scope(event)
end

local function with_event(op, event)
  if not event then
    return op
  end
  return op:and_then(function(...)
    local values = Op._pack(...)
    return Op.emit(event_of(event)):map(function()
      return unpack_(values, 1, values.n)
    end)
  end, false)
end

local function region_state(s, region)
  return s.regions[region]
    or {
      sealed = region.sealed == true,
      version = region.version or 0,
      count = 0,
      next_admission = 0,
      records = pmap(nil),
      order = nil,
      seen = pmap(nil),
    }
end

local function ensure_region(s, region)
  if not pmap_local(s.regions, region) then
    local existing = s.regions[region]
    if existing == nil then
      s.region_count = (s.region_count or 0) + 1
    end
    s.regions[region] = copy_region_state(existing, region)
  end
  s.dirty_regions[region] = true
  return s.regions[region]
end
local function record_set(s, region, rs, item, value)
  local old = rs.records[item]
  if value ~= nil and not rs.seen[item] then
    rs.seen[item] = true
    rs.order = { key = pmap_key(item), next = rs.order }
  end
  rs.records[item] = value
  if old == nil and value ~= nil then
    rs.count = (rs.count or 0) + 1
  elseif old ~= nil and value == nil then
    rs.count = math.max((rs.count or 1) - 1, 0)
    if rs.count == 0 then
      rs.records, rs.seen, rs.order = pmap(nil), pmap(nil), nil
    else
      -- Remove the retired record from persistent parents immediately. Stale
      -- order nodes carry only integer ledger keys, but old record values carry
      -- the item and settlement graph.
      local records = pmap_flatten(rs.records)
      local order, seen = compact_region_order(records, rs.order)
      rs.records, rs.order, rs.seen = records, order, seen
    end
  end
  s.dirty_items[item] = true
  s.dirty_regions[region] = true
end
local function owner_set(s, item, owner)
  local old = s.owners[item]
  s.owners[item] = owner
  if old == nil and owner ~= nil then
    s.owner_count = (s.owner_count or 0) + 1
  elseif old ~= nil and owner == nil then
    s.owner_count = math.max((s.owner_count or 1) - 1, 0)
    if s.owner_count == 0 then
      s.owners = pmap(nil)
    else
      -- Do not let a tombstoned owner remain strongly reachable through a
      -- persistent parent chain.
      s.owners = pmap_flatten(s.owners)
    end
  end
  s.dirty_items[item] = true
end
local function each_record(rs, fn)
  local node = rs.order
  while node do
    local rec = rs.records[node.key]
    if rec ~= nil then
      fn(rec.item, rec)
    end
    node = node.next
  end
end
local function bump(rs)
  rs.version = (rs.version or 0) + 1
end

local function collect_subtree(records, root, out)
  out = out or {}
  local rec = records[root]
  if not rec or out[root] then
    return out
  end
  out[root] = rec
  for i = 1, #(rec.children or {}) do
    collect_subtree(records, rec.children[i], out)
  end
  return out
end

local function subtree_list(records, root, public)
  local out = {}
  local function walk(item)
    local rec = records[item]
    if not rec then
      return
    end
    out[#out + 1] = copy_record(rec, public)
    for i = 1, #(rec.children or {}) do
      walk(rec.children[i])
    end
  end
  walk(root)
  return out
end

local function sorted_items(region_state_value, roots_only)
  local rows = {}
  each_record(region_state_value, function(item, rec)
    if not roots_only or rec.parent == nil then
      rows[#rows + 1] = { item = item, admission_order = rec.admission_order or 0 }
    end
  end)
  table.sort(rows, function(a, b)
    if roots_only and a.admission_order ~= b.admission_order then
      -- Scope retirement unwinds independent roots in reverse admission order.
      return a.admission_order > b.admission_order
    end
    return tostring(a.item._fibers_id or a.item.name or a.item)
      < tostring(b.item._fibers_id or b.item.name or b.item)
  end)
  local out = {}
  for i = 1, #rows do
    out[i] = rows[i].item
  end
  return out
end

local function rights_allow(rights, right)
  if right == nil or rights == nil or rights == '*' then
    return true
  end
  if type(rights) == 'string' then
    return rights == right or rights == '*'
  end
  if type(rights) ~= 'table' then
    return false
  end
  if rights[right] == true or rights['*'] == true then
    return true
  end
  for i = 1, #rights do
    if rights[i] == right or rights[i] == '*' then
      return true
    end
  end
  return false
end

local Owned = {}

local function owned_spec(item, settle, children, opts)
  if type(item) ~= 'table' or item._fibers_kind ~= OwnershipKind then
    error('Region.Owned expects an owned handle', 3)
  end
  opts = opts or {}
  return {
    _fibers_owned_spec = true,
    _fibers_value = true,
    item = item,
    settle = Settlement.protocol(settle, 'Region.Owned settle'),
    settle_name = opts.settle_name or Settlement.name_of(settle, settle == nil and 'none' or nil),
    role = opts.role,
    meta = opts.meta,
    rights = opts.rights,
    children = children or {},
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
  return owned_spec(item, Settlement.none(), nil, opts)
end
function Owned.is(x)
  return type(x) == 'table' and x._fibers_owned_spec == true
end
function Owned.from_item(item)
  if Owned.is(item) then
    return item
  end
  if type(item) ~= 'table' or item._fibers_kind ~= OwnershipKind then
    error('owned admission expects a Region.Owned value or owned handle', 3)
  end
  return owned_spec(item, item._fibers_settle, nil, {
    role = item._fibers_obligation_kind,
    settle_name = item._fibers_settle_name or 'none',
  })
end

local function spec_to_records(spec, parent, out)
  spec = Owned.from_item(spec)
  out = out or {}
  if out[spec.item] then
    error('Owned tree contains duplicate item', 3)
  end
  local rec = {
    _fibers_value = true,
    item = spec.item,
    settle = spec.settle,
    settle_name = spec.settle_name,
    role = spec.role,
    parent = parent,
    children = {},
    phase = Phase.live,
    rights = spec.rights,
    meta = spec.meta,
  }
  out[spec.item] = rec
  for i = 1, #(spec.children or {}) do
    local child = Owned.from_item(spec.children[i])
    rec.children[#rec.children + 1] = child.item
    spec_to_records(child, spec.item, out)
  end
  return out, spec.item
end

local function transition(spec)
  return Scalar.transition(spec)
end

local function op_transition(t, payload)
  return ledger:transition_op(t, payload or {})
end

local function query_transition(name, fn)
  return transition({
    name = name,
    mode = 'query',
    order = 10,
    accepts_supply = false,
    supplies = 'none',
    step = function(s, p)
      return Ready.same(fn(s, p))
    end,
  })
end

local function select_transition(name, ready, step, order)
  return transition({
    name = name,
    mode = 'select',
    order = order or 50,
    accepts_supply = false,
    supplies = 'none',
    ready = ready,
    step = function(s, p)
      if not ready(s, p) then
        return Wait
      end
      return step(s, p)
    end,
  })
end

function Region.owned(item, settle, opts)
  return Owned.item(item, settle, opts)
end
function Region.inert(item, opts)
  return Owned.inert(item, opts)
end

function Region.new(name)
  next_region = next_region + 1
  local id = 'region-' .. tostring(next_region)
  local region = setmetatable({
    name = name or id,
    owned = {},
    owned_count = 0,
    sealed = false,
    version = 0,
    _fibers_id = id,
    _fibers_kind = Kind,
  }, Region)
  return region
end

function Region:admit_op(item_or_owned, from_owner)
  local records, root = spec_to_records(Owned.from_item(item_or_owned))
  local t = select_transition('region.admit', function(s)
    local rs = region_state(s, self)
    if rs.sealed then
      return false
    end
    for item in pairs(records) do
      local owner = s.owners[item]
      if owner ~= nil and owner ~= from_owner then
        return false
      end
    end
    return true
  end, function(s)
    local ns = clone_ledger(s)
    local rs = ensure_region(ns, self)
    rs.next_admission = (rs.next_admission or 0) + 1
    local admission_order = rs.next_admission
    for item, rec in pairs(records) do
      local nr = copy_record(rec, false)
      if item == root then
        nr.admission_order = admission_order
      end
      record_set(ns, self, rs, item, nr)
      owner_set(ns, item, self)
    end
    bump(rs)
    return Ready.write(ns, root)
  end, 40)
  return with_event(op_transition(t), {
    type = 'admitted',
    item = root,
    item_id = root._fibers_id,
    from = from_owner,
    to = self,
    to_id = self._fibers_id,
  })
end

function Region:release_op(item)
  local t = select_transition('region.release', function(s)
    local rs = region_state(s, self)
    local rec = rs.records[item]
    if s.owners[item] ~= self or not rec or rec.parent ~= nil or rec.phase ~= Phase.live then
      return false
    end
    for i = 1, #(rec.children or {}) do
      if rs.records[rec.children[i]] then
        return false
      end
    end
    return true
  end, function(s)
    local ns = clone_ledger(s)
    local rs = ensure_region(ns, self)
    record_set(ns, self, rs, item, nil)
    owner_set(ns, item, nil)
    bump(rs)
    return Ready.write(ns, item)
  end)
  return with_event(op_transition(t), {
    type = 'released',
    item = item,
    item_id = item._fibers_id,
    from = self,
    from_id = self._fibers_id,
    to = nil,
  })
end

function Region:move_op(item, to_region)
  local t = select_transition('region.move', function(s)
    local from, to = region_state(s, self), region_state(s, to_region)
    local rec = from.records[item]
    if to.sealed or s.owners[item] ~= self or not rec or rec.parent ~= nil then
      return false
    end
    local subtree = collect_subtree(from.records, item)
    for _, r in pairs(subtree) do
      if r.phase ~= Phase.live then
        return false
      end
    end
    return true
  end, function(s)
    if to_region == self then
      return Ready.write(clone_ledger(s), item)
    end
    local ns = clone_ledger(s)
    local from, to = ensure_region(ns, self), ensure_region(ns, to_region)
    local subtree = collect_subtree(from.records, item)
    to.next_admission = (to.next_admission or 0) + 1
    local admission_order = to.next_admission
    for child, rec in pairs(subtree) do
      record_set(ns, self, from, child, nil)
      local nr = copy_record(rec, false)
      if child == item then
        nr.admission_order = admission_order
      end
      record_set(ns, to_region, to, child, nr)
      owner_set(ns, child, to_region)
    end
    bump(from)
    bump(to)
    return Ready.write(ns, item)
  end)
  return with_event(op_transition(t), {
    type = 'moved',
    item = item,
    item_id = item._fibers_id,
    from = self,
    to = to_region,
    from_id = self._fibers_id,
    to_id = to_region._fibers_id,
  })
end

function Region:claim_op(item, purpose)
  local t = select_transition('region.claim', function(s)
    local rs = region_state(s, self)
    local root = rs.records[item]
    if s.owners[item] ~= self or not root or root.parent ~= nil then
      return false
    end
    local subtree = collect_subtree(rs.records, item)
    for _, rec in pairs(subtree) do
      if rec.phase ~= Phase.live then
        return false
      end
    end
    return true
  end, function(s)
    local ns = clone_ledger(s)
    local rs = ensure_region(ns, self)
    local records = subtree_list(rs.records, item, false)
    local claim = Claim.new(self, item, records, purpose)
    local subtree = collect_subtree(rs.records, item)
    for child, rec in pairs(subtree) do
      local nr = copy_record(rec, false)
      nr.phase = Phase.claimed
      nr.claim = claim
      nr.claim_id = claim.id
      nr.claim_purpose = purpose
      nr.claim_reason = claim.reason
      record_set(ns, self, rs, child, nr)
    end
    bump(rs)
    return Ready.write(ns, claim)
  end)
  return op_transition(t)
end

local function valid_claim(s, region, claim)
  if not Claim.is(claim) or claim.region ~= region then
    return nil
  end
  local rs = region_state(s, region)
  local root = rs.records[claim.root]
  if not root or root.claim ~= claim then
    return nil
  end
  local subtree = collect_subtree(rs.records, claim.root)
  for _, rec in pairs(subtree) do
    if rec.claim ~= claim or (rec.phase ~= Phase.claimed and rec.phase ~= Phase.failed) then
      return nil
    end
  end
  return subtree
end

function Region:resolve_op(claim, resolution)
  resolution = resolution or { kind = 'discharge' }
  local requested_kind = resolution.kind or resolution
  if requested_kind == 'restore' and Claim.is(claim) and claim.started then
    error('a settlement claim cannot be restored after settlement has begun', 2)
  end
  if requested_kind == 'discharge' and Claim.is(claim) and claim.started and not claim.complete then
    error('an incomplete settlement claim cannot be discharged', 2)
  end
  if requested_kind == 'resume' and (not Claim.is(claim) or not claim.started or claim.complete) then
    error('only an incomplete started settlement claim can be resumed', 2)
  end
  local t = select_transition('region.resolve_claim', function(s)
    return valid_claim(s, self, claim) ~= nil
  end, function(s)
    local ns = clone_ledger(s)
    local rs = ensure_region(ns, self)
    local subtree = valid_claim(ns, self, claim)
    local kind = resolution.kind or resolution
    if kind == 'discharge' then
      for child in pairs(subtree) do
        record_set(ns, self, rs, child, nil)
        owner_set(ns, child, nil)
      end
    elseif kind == 'resume' then
      for child, rec in pairs(subtree) do
        local nr = copy_record(rec, false)
        nr.phase = Phase.claimed
        nr.settlement_failed = nil
        nr.settlement_error = nil
        nr.settlement_error_message = nil
        record_set(ns, self, rs, child, nr)
      end
    elseif kind == 'restore' then
      for child, rec in pairs(subtree) do
        local nr = copy_record(rec, false)
        nr.phase = Phase.live
        nr.claim = nil
        nr.claim_id = nil
        nr.claim_purpose = nil
        nr.claim_reason = nil
        nr.settlement_failed = nil
        nr.settlement_error = nil
        nr.settlement_error_message = nil
        nr.settlement_state = nil
        nr.settlement_request_state = nil
        nr.settlement_force_state = nil
        nr.settlement_request_error = nil
        nr.settlement_force_error = nil
        record_set(ns, self, rs, child, nr)
      end
    elseif kind == 'fail' then
      local progress_by_item = {}
      for i = 1, #(resolution.progress or {}) do
        local entry = resolution.progress[i]
        progress_by_item[entry.item] = entry
      end
      local first_error = resolution.error
      if first_error == nil and resolution.failures and resolution.failures[1] then
        first_error = resolution.failures[1].error
      end
      for child, rec in pairs(subtree) do
        local nr = copy_record(rec, false)
        local progress = progress_by_item[child]
        nr.phase = Phase.failed
        nr.settlement_state = progress and progress.state or 'failed'
        nr.settlement_request_state = progress and progress.request_state or nil
        nr.settlement_force_state = progress and progress.force_state or nil
        nr.settlement_request_error = progress and progress.request_error or nil
        nr.settlement_force_error = progress and progress.force_error or nil
        nr.settlement_failed = not progress or progress.settlement_state ~= 'succeeded'
        nr.settlement_error = progress
            and (progress.settlement_error or progress.request_error or progress.force_error)
          or first_error
        nr.settlement_error_message = nr.settlement_error and tostring(nr.settlement_error) or nil
        record_set(ns, self, rs, child, nr)
      end
    else
      error('unknown claim resolution ' .. tostring(kind), 0)
    end
    bump(rs)
    return Ready.write(ns, claim.root)
  end)
  return op_transition(t)
end
function Region:discharge_claim_op(claim)
  return self:resolve_op(claim, { kind = 'discharge' })
end
function Region:fail_claim_op(claim, err)
  return self:resolve_op(claim, { kind = 'fail', error = err })
end
function Region:restore_claim_op(claim)
  return self:resolve_op(claim, { kind = 'restore' })
end

function Region:seal_op()
  local t = select_transition('region.seal', function(s)
    return not region_state(s, self).sealed
  end, function(s)
    local ns = clone_ledger(s)
    local rs = ensure_region(ns, self)
    rs.sealed = true
    bump(rs)
    return Ready.write(ns, true)
  end)
  return op_transition(t)
end

function Region:is_open_op()
  return op_transition(query_transition('region.is_open', function(s)
    return not region_state(s, self).sealed
  end))
end

function Region:changed_op(version)
  local t = select_transition('region.changed', function(s)
    return region_state(s, self).version ~= version
  end, function(s)
    return Ready.same(region_state(s, self).version)
  end)
  return op_transition(t)
end

function Region:owns_op(item)
  return op_transition(query_transition('region.owns', function(s)
    return s.owners[item] == self
  end))
end

function Region:record_op(item)
  return op_transition(query_transition('region.record', function(s)
    return copy_record(region_state(s, self).records[item], true)
  end))
end

function Region:children_op(item)
  return op_transition(query_transition('region.children', function(s)
    local rec = region_state(s, self).records[item]
    return rec and copy_list(rec.children) or nil
  end))
end

function Region:subtree_op(item)
  return op_transition(query_transition('region.subtree', function(s)
    local rs = region_state(s, self)
    if not rs.records[item] then
      return nil
    end
    return subtree_list(rs.records, item, true)
  end))
end

function Region:members_op()
  return op_transition(query_transition('region.members', function(s)
    return sorted_items(region_state(s, self), false)
  end))
end
function Region:roots_op()
  return op_transition(query_transition('region.roots', function(s)
    return sorted_items(region_state(s, self), true)
  end))
end
function Region:snapshot_op()
  return op_transition(query_transition('region.snapshot', function(s)
    local rs = region_state(s, self)
    local owned, roots, claimed, failed = 0, 0, 0, 0
    each_record(rs, function(_, rec)
      owned = owned + 1
      if rec.parent == nil then
        roots = roots + 1
      end
      if rec.phase == Phase.claimed then
        claimed = claimed + 1
      end
      if rec.phase == Phase.failed or rec.settlement_failed then
        failed = failed + 1
      end
    end)
    return {
      sealed = rs.sealed,
      open = not rs.sealed,
      owned_count = owned,
      root_count = roots,
      claimed_count = claimed,
      failed_count = failed,
      settlement_failed_count = failed,
      version = rs.version,
    }
  end))
end
function Region:live_op(item)
  return op_transition(query_transition('region.live', function(s)
    local rec = region_state(s, self).records[item]
    return s.owners[item] == self and rec ~= nil and rec.phase == Phase.live
  end))
end
function Region:authorise_op(item, right, opts)
  opts = opts or {}
  return op_transition(query_transition('region.authorise', function(s)
    local rec = region_state(s, self).records[item]
    if s.owners[item] ~= self or not rec then
      return false, nil
    end
    local phase = rec.phase
    local phase_ok = phase == Phase.live or (opts.allow_claimed == true and phase == Phase.claimed)
    local rights = rec.rights
    if rights == nil and type(rec.meta) == 'table' then
      rights = rec.meta.rights
    end
    return phase_ok and rights_allow(rights, right), phase
  end))
end

Region.Kind = Kind
Region.Phase = Phase
Region.Owned = Owned
Region.handle = ownership_handle
Region.OwnershipKind = OwnershipKind
Region.Claim = Claim
return Region
