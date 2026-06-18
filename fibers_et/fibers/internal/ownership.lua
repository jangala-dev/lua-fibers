-- Internal ownership record used by Region and owned handles such as Task.
--
-- Ownership is the small transactional owner record beneath Regions.  A Region validates admission,
-- sealing and membership; the ownership record is where item owner transitions
-- become concrete and where standard lifetime effects are derived.

local ConsequenceSet = require('fibers.kernel.consequence.set')
local Effect = require('fibers.base.effect')
local Settlement = require('fibers.internal.settlement')

local Ownership = {}

local Kind = { name = 'ownership' }

local function owner_id(owner)
  return owner and (owner._fibers_id or owner.name) or nil
end

local function item_kind(item)
  return item and (item._fibers_obligation_kind or item._fibers_lifetime_kind or item._fibers_kind_name or item._fibers_id and 'owned' or nil)
end

local function transition_type(old_owner, new_owner)
  if old_owner == new_owner then return nil end
  if old_owner == nil and new_owner ~= nil then return 'admitted' end
  if old_owner ~= nil and new_owner == nil then return 'released' end
  if old_owner ~= nil and new_owner ~= nil then return 'reassigned' end
  return nil
end

function Kind.clone(rec)
  return { kind = Kind, read = rec.read, owner_set = rec.owner_set, owner = rec.owner }
end

function Kind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.owner_set then dst.owner_set = true; dst.owner = src.owner end
  return true
end

function Kind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if src.owner_set then
    if dst.owner_set and dst.owner ~= src.owner then return false, 'owner-conflict' end
    dst.owner_set = true
    dst.owner = src.owner
  end
  return true
end

function Kind.project(item, rec, query)
  if query ~= 'owner' then return nil, false end
  if rec and rec.owner_set then return rec.owner, true end
  return item.owner, true
end

function Kind.prepare(item, rec, _resolve)
  if rec.read ~= nil and (item.owner_version or 0) ~= rec.read then return nil, 'stale' end
  if not rec.owner_set then return nil, nil, true end

  local old_owner = item.owner
  local new_owner = rec.owner
  local prepared = { kind = Kind, resource = item, owner = new_owner, old_owner = old_owner }
  local typ = transition_type(old_owner, new_owner)
  if typ then
    local consequence_set = ConsequenceSet.empty()
    local ok, err = consequence_set:add(Effect.lifetime {
      type = typ,
      item = item,
      item_id = item._fibers_id,
      item_kind = item_kind(item),
      from = old_owner,
      to = new_owner,
      from_id = owner_id(old_owner),
      to_id = owner_id(new_owner),
    })
    if not ok then return nil, err end
    prepared.consequence_set = consequence_set
  end
  return prepared
end

function Kind.apply(prepared, _log)
  local item = prepared.resource
  item.owner = prepared.owner
  item.owner_version = (item.owner_version or 0) + 1
end


local next_handle = 0

function Ownership.handle(name, fields)
  next_handle = next_handle + 1
  local id = 'owned-' .. tostring(next_handle)
  local h = fields or {}
  h.name = name or h.name or id
  h.owner = h.owner
  h.owner_version = h.owner_version or 0
  h._fibers_id = h._fibers_id or id
  h._fibers_kind = Kind
  h._fibers_obligation_kind = h._fibers_obligation_kind or h.kind
  h._fibers_settle = h._fibers_settle or h.settle or Settlement.none()
  h._fibers_settle_name = h._fibers_settle_name or h.settle_name or 'none'
  return h
end

Ownership.Kind = Kind
return Ownership
