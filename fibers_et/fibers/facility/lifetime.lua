-- Lifetime: compound transactional lifetime facility.
--
-- A Lifetime is not a new kernel primitive. It is a useful composition over the
-- base kit: Region supplies ownership, Source supplies observation, Task
-- supplies the standard owned computation, and Effects publish committed
-- lifetime transitions.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Source = require('fibers.base.source')
local Channel = require('fibers.base.channel')
local Cell = require('fibers.base.cell')
local Task = require('fibers.base.task')
local Effect = require('fibers.base.effect')
local Settlement = require('fibers.internal.settlement')

local Lifetime = {}
Lifetime.__index = Lifetime

local next_id = 0

local function is_region(x)
  return type(x) == 'table' and x._fibers_kind == Region.Kind
end


local function target_region(target)
  if type(target) ~= 'table' then return nil end
  if target._fibers_lifetime then return target.region end
  if is_region(target) then return target end
  return nil
end

local function target_lifetime(target)
  if type(target) == 'table' and target._fibers_lifetime then return target end
  return nil
end

local function item_kind(item)
  return item and (item._fibers_obligation_kind or item._fibers_lifetime_kind or item._fibers_kind_name or item._fibers_id and 'owned' or nil)
end

local function emit_all(effects, value)
  local p = Op.always(true)
  for i = 1, #effects do
    p = p:and_then(function() return Op.emit(effects[i]) end)
  end
  return p:map(function() return value end)
end

local function new_handoff(name)
  return Channel.new(name)
end

function Lifetime.new(name, opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'lifetime-' .. tostring(next_id)
  local region = opts.region or Region.new(name or id)
  if not is_region(region) then error('Lifetime.new expects opts.region to be a Region', 2) end
  return setmetatable({
    name = name or region.name or id,
    region = region,
    state = opts.state or Cell.new({ phase = 'open', sealed = false, settled = false }, (name or id) .. '-state'),
    events = opts.events or Source.queue((name or id) .. '-events'),
    handoff = opts.handoff or new_handoff((name or id) .. '-handoff'),
    _fibers_id = id,
    _fibers_lifetime = true,
      }, Lifetime)
end

function Lifetime:raw_region()
  return self.region
end

function Lifetime:event_source()
  return self.events
end


function Lifetime:next_event_op()
  return self.events:next_op()
end

function Lifetime:region_op()
  return Op.always(self.region)
end

local function fill_event_fields(life, typ, fields)
  fields = fields or {}
  local item = fields.item or fields.task
  fields.type = fields.type or typ
  fields.lifetime = fields.lifetime or life
  fields.lifetime_id = fields.lifetime_id or life._fibers_id
  fields.region = fields.region or life.region
  fields.source = fields.source or life.events
  if item ~= nil then
    fields.item = item
    fields.item_id = fields.item_id or item._fibers_id
    fields.item_kind = fields.item_kind or item_kind(item)
    if fields.item_kind == 'task' then fields.task = fields.task or item end
  end
  if fields.from_lifetime and not fields.from then fields.from = fields.from_lifetime.region end
  if fields.to_lifetime and not fields.to then fields.to = fields.to_lifetime.region end
  fields.from_id = fields.from_id or (fields.from and (fields.from._fibers_id or fields.from.name))
  fields.to_id = fields.to_id or (fields.to and (fields.to._fibers_id or fields.to.name))
  return fields
end

function Lifetime:_event(typ, fields)
  return Effect.lifetime(fill_event_fields(self, typ, fields))
end

function Lifetime:_event_for_target(target, typ, fields)
  local life = target_lifetime(target)
  if not life then return nil end
  return Effect.lifetime(fill_event_fields(life, typ, fields))
end

function Lifetime:spawn_op(fn, opts)
  return Task.spawn_op(self.region, fn, opts):and_then(function(task)
    return emit_all({ self:_event('admitted', { item = task, task = task, item_kind = 'task' }) }, task)
  end)
end

function Lifetime:request_cancel_op(item, reason)
  return self.region:record_op(item):and_then(function(record)
    if not record then return Op.never() end
    if type(item.request_cancel_op) == 'function' then
      return item:request_cancel_op(reason):and_then(function()
        return emit_all({ self:_event('cancel_requested', { item = item, task = item, reason = reason, settle = record.settle_name }) }, item)
      end)
    elseif type(item.shutdown_op) == 'function' then
      return item:shutdown_op(reason):and_then(function()
        return emit_all({ self:_event('cancel_requested', { item = item, reason = reason, settle = record.settle_name }) }, item)
      end)
    end
    return Op.never()
  end)
end

function Lifetime:handoff_op(item, target)
  local r = target_region(target)
  if not r then error('Lifetime:handoff_op expects a target Lifetime or Region', 2) end
  return self.region:reassign_op(item, r):and_then(function()
    local effects = { self:_event('handed_off', { item = item, task = item, to = r, to_lifetime = target_lifetime(target) }) }
    local recv = self:_event_for_target(target, 'handoff_received', { item = item, task = item, from = self.region, from_lifetime = self })
    if recv then effects[#effects + 1] = recv end
    return emit_all(effects, item)
  end)
end

function Lifetime:offer_handoff_op(item, target)
  local target_life = target_lifetime(target)
  if not target_life then error('Lifetime:offer_handoff_op expects a target Lifetime', 2) end
  local offer = {
    type = 'handoff_offer',
    from = self,
    from_lifetime = self,
    to = target_life,
    to_lifetime = target_life,
    item = item,
    task = item,
    item_kind = item_kind(item),
    name = item and item.name or nil,
  }
  return self:handoff_op(item, target_life):and_then(function()
    return target_life.handoff:put_op(offer):map(function() return offer end)
  end)
end

function Lifetime:accept_handoff_op()
  return self.handoff:get_op()
end

function Lifetime:settle_item_op(item, reason)
  return Settlement.settle_item_op(self, item, reason, function(ctx, claim)
    return emit_all({ ctx:_event('settled_item', {
      item = item,
      task = item,
      claim = claim,
      claim_id = claim.id,
      purpose = claim.purpose,
      settle = claim.records[1] and claim.records[1].settle_name,
    }) }, item)
  end)
end
function Lifetime:close_op(reason)
  return self.region:seal_op():and_then(function()
    return self.state:write_op({ phase = 'closed', sealed = true, settled = false, reason = reason })
  end):and_then(function()
    return emit_all({ self:_event('closed', { reason = reason }) }, true)
  end)
end

function Lifetime:settle_op()
  return self.region:snapshot_op():and_then(function(region_status)
    if not (region_status.sealed and (region_status.owned_count or 0) == 0) then return Op.never() end
    return self.state:read_op():and_then(function(v)
      if type(v) == 'table' and v.settled then return Op.never() end
      return self.state:write_op({ phase = 'settled', sealed = true, settled = true, reason = type(v) == 'table' and v.reason or nil })
    end)
  end):and_then(function()
    return emit_all({ self:_event('settled') }, true)
  end)
end

function Lifetime:owns_op(item)
  return self.region:owns_op(item)
end

function Lifetime:items_op()
  return self.region:members_op()
end

function Lifetime:state_op()
  return self.region:snapshot_op():and_then(function(region_status)
    return self.state:read_op():map(function(lifetime_status)
      return {
        open = region_status.open,
        sealed = region_status.sealed,
        settled = type(lifetime_status) == 'table' and lifetime_status.settled or false,
        phase = type(lifetime_status) == 'table' and lifetime_status.phase or (region_status.sealed and 'closed' or 'open'),
        owned_count = region_status.owned_count,
        region = self.region,
        lifetime = self,
      }
    end)
  end)
end

Lifetime.Region = Region
return Lifetime
