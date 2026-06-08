-- Lifetime: compound transactional lifetime facility.
--
-- A Lifetime is not a new kernel primitive. It is a useful composition over the
-- base kit: Region supplies ownership, Source supplies observation, Task
-- supplies the standard owned computation, and Effects publish committed
-- lifetime transitions.

local DefaultOp = require('fibers.op')
local Region = require('fibers.region')
local Source = require('fibers.source')
local Channel = require('fibers.channel')
local Task = require('fibers.task')
local Effect = require('fibers.effect')

local Lifetime = {}
Lifetime.__index = Lifetime

local next_id = 0

local function is_region(x)
  return type(x) == 'table' and x._fibers_kind == Region.Kind
end

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
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

local function emit_all(Op, effects, value)
  local p = Op.always(true)
  for i = 1, #effects do
    p = p:and_then(function() return Op.emit(effects[i]) end)
  end
  return p:map(function() return value end)
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
    events = opts.events or Source.manual((name or id) .. '-events'),
    handoff = opts.handoff or Channel.new((name or id) .. '-handoff'),
    _fibers_id = id,
    _fibers_lifetime = true,
    _fibers_value = true,
  }, Lifetime)
end

function Lifetime:raw_region()
  return self.region
end

function Lifetime:event_source()
  return self.events
end

Lifetime.events_source = Lifetime.event_source

function Lifetime:watch_op(Op)
  return self.events:next_op(Op)
end

function Lifetime:region_op()
  return DefaultOp.always(self.region)
end

function Lifetime:_event(typ, fields)
  fields = fields or {}
  fields.type = fields.type or typ
  fields._fibers_value = true
  fields.lifetime = fields.lifetime or self
  fields.lifetime_id = fields.lifetime_id or self._fibers_id
  fields.region = fields.region or self.region
  fields.source = fields.source or self.events
  return Effect.lifetime(fields)
end

function Lifetime:_event_for_target(target, typ, fields)
  local life = target_lifetime(target)
  if not life then return nil end
  fields = fields or {}
  fields.type = fields.type or typ
  fields._fibers_value = true
  fields.lifetime = fields.lifetime or life
  fields.lifetime_id = fields.lifetime_id or life._fibers_id
  fields.region = fields.region or life.region
  fields.source = fields.source or life.events
  return Effect.lifetime(fields)
end

function Lifetime:spawn_op(a, b, c)
  local Op, fn, opts
  if is_op_module(a) then Op, fn, opts = a, b, c else Op, fn, opts = DefaultOp, a, b end
  return Task.spawn_op(Op, self.region, fn, opts):and_then(function(task)
    return emit_all(Op, { self:_event('task_admitted', { item = task, task = task, item_kind = 'task' }) }, task)
  end)
end

function Lifetime:cancel_op(a, b, c)
  local Op, item, reason
  if is_op_module(a) then Op, item, reason = a, b, c else Op, item, reason = DefaultOp, a, b end
  return self.region:cancel_op(Op, item, reason):and_then(function()
    return emit_all(Op, { self:_event('task_cancel_requested', { item = item, task = item, reason = reason }) }, item)
  end)
end

function Lifetime:transfer_op(a, b, c)
  local Op, item, target
  if is_op_module(a) then Op, item, target = a, b, c else Op, item, target = DefaultOp, a, b end
  local r = target_region(target)
  if not r then error('Lifetime:transfer_op expects a target Lifetime or Region', 2) end
  return self.region:transfer_op(Op, item, r):and_then(function()
    local effects = { self:_event('task_transferred', { item = item, task = item, to = r, to_lifetime = target_lifetime(target) }) }
    local recv = self:_event_for_target(target, 'task_received', { item = item, task = item, from = self.region, from_lifetime = self })
    if recv then effects[#effects + 1] = recv end
    return emit_all(Op, effects, item)
  end)
end


function Lifetime:offer_op(a, b, c)
  local Op, item, target
  if is_op_module(a) then Op, item, target = a, b, c else Op, item, target = DefaultOp, a, b end
  local target_life = target_lifetime(target)
  if not target_life then error('Lifetime:offer_op expects a target Lifetime', 2) end
  local offer = {
    type = 'handoff_offer',
    from = self,
    to = target_life,
    item = item,
    task = item,
    _fibers_value = true,
  }
  return self:transfer_op(Op, item, target_life):and_then(function()
    return target_life.handoff:put_op(Op, offer):map(function() return offer end)
  end)
end

function Lifetime:accept_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return self.handoff:get_op(Op)
end

function Lifetime:release_op(a, b)
  local Op, item
  if is_op_module(a) then Op, item = a, b else Op, item = DefaultOp, a end
  return self.region:settle_op(Op, item):and_then(function()
    return emit_all(Op, { self:_event('task_released', { item = item, task = item }) }, item)
  end)
end

function Lifetime:seal_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return self.region:seal_op(Op):and_then(function()
    return emit_all(Op, { self:_event('region_sealed', { reason = nil }) }, true)
  end)
end

function Lifetime:owns_op(a, b)
  return self.region:owns_op(a, b)
end

function Lifetime:status_op(Op)
  return self.region:status_op(Op)
end

Lifetime.Region = Region
return Lifetime
