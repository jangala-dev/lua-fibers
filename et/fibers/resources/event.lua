-- Manual waitable event resource for exercising wakeup semantics.
local DefaultOp = require('fibers.op')
local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')

local Event = {}
Event.__index = Event

local EventKind = { name = 'event' }
local next_id = 0

function EventKind.eval(event, payload, _ctx)
  if payload.op ~= 'wait' then error('unknown event operation ' .. tostring(payload.op), 2) end
  if event.ready then return Result.cands({ Candidate.new(event.vals or DefaultOp._pack(true)) }) end
  return Result.wait({
    kind = 'wakeup',
    primitive = 'manual_event',
    source = event,
    interest = payload.interest or 'ready',
  })
end

function EventKind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
end

function Event.new(name)
  next_id = next_id + 1
  return setmetatable({
    name = name or ('event-' .. tostring(next_id)),
    _fibers_id = 'event-' .. tostring(next_id),
    _fibers_kind = EventKind,
    ready = false,
    vals = nil,
  }, Event)
end

function Event:set(...)
  self.ready = true
  self.vals = { n = select('#', ...), ... }
end

function Event:clear()
  self.ready = false
  self.vals = nil
end

function Event:wait_op(Op)
  return Op._resource(self, EventKind, { op = 'wait', interest = 'ready' })
end

Event.Kind = EventKind

return Event
