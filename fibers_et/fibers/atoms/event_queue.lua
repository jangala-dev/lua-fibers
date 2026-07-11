local Op = require('fibers.atoms.op')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Validity = require('fibers.kernel.validity')
local Common = require('fibers.atoms.external_common')

local pack_ = Op._pack
local EventQueue = {}
EventQueue.__index = EventQueue
local Kind = { name = 'event-queue' }

local function deliver(queue, ...)
  queue._validity:push(pack_(...), 'event arrival')
end

local function clear(queue)
  queue._validity:clear('events cleared')
end

function EventQueue.new(name)
  local queue = Common.new('events', EventQueue, Kind, { name = name }, Validity.queue)
  queue._fibers_external_deliver = deliver
  queue._fibers_external_clear = clear
  return queue
end

local function count(queue) return queue._validity:count() end
local function head(queue) return queue._validity.head or 1 end

local function ensure_record(proposal, queue)
  local rec = Resource.ensure(proposal, queue, Kind)
  rec.take = rec.take or 0
  return rec
end

function Kind.clone(rec)
  return { kind = Kind, take = rec.take or 0, head = rec.head }
end

function Kind.merge_seq(dst, src)
  if src.head ~= nil and dst.head == nil then dst.head = src.head end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function Kind.merge_par(dst, src)
  if src.head ~= nil and dst.head == nil then dst.head = src.head end
  if (dst.take or 0) > 0 and (src.take or 0) > 0 then
    return false, 'event-queue-parallel-consume-conflict'
  end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function Kind.project(queue, rec, query)
  local take = rec and rec.take or 0
  if query == 'count' then return count(queue) - take, true end
  if query == 'next' then return queue._validity:peek(nil, take), true end
  return nil, false
end

function Kind.prepare(queue, rec)
  local take = rec.take or 0
  if take <= 0 then return nil, nil, true end
  if rec.head ~= nil and head(queue) ~= rec.head then return nil, 'stale' end
  if count(queue) < take then return nil, 'stale' end
  return { kind = Kind, resource = queue, take = take, head = rec.head or head(queue) }
end

function Kind.apply(prepared)
  local ok, err = prepared.resource._validity:take(prepared.take or 0, 'event head consumed')
  if not ok then error(err or 'event consume failed') end
end

function Kind.eval(queue, payload, ctx)
  if payload.op ~= 'next' and payload.op ~= 'drain' then error('event queues support next_op and _drain_op', 2) end
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[queue]
  local take = rec and rec.take or 0
  local value = queue._validity:peek(ctx, take)
  if value == nil then
    local frontier = queue._validity:frontier_for('events.empty')
    ctx:add({ kind = 'events-empty', resource = queue, frontier = frontier, stamp = frontier.gen })
    return ctx:retry('events-empty', Common.interest(ctx, queue, 'next', { external_kind = 'events' }))
  end
  local proposal
  local take_count = 1
  if payload.op == 'drain' then
    take_count = count(queue) - take
    local values = {}
    for i = 0, take_count - 1 do values[#values + 1] = queue._validity:peek(ctx, take + i) end
    proposal = Proposal.new(Op._pack(values))
  else
    proposal = Proposal.new(value)
  end
  local out = ensure_record(proposal, queue)
  out.head = out.head or head(queue)
  out.take = (out.take or 0) + take_count
  return Result.ready(proposal)
end

function Kind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
  out.resources = true
  out.reads = true
  out.writes = true
  out.needs_overlay = true
end

function EventQueue:next_op()
  return Op._resource(self, Kind, { op = 'next' })
end

-- Internal batch drain used by scope policy monitors. Values are returned as
-- the packed arrivals stored by the external queue.
function EventQueue:_drain_op()
  return Op._resource(self, Kind, { op = 'drain' })
end

EventQueue.Kind = Kind
return EventQueue
