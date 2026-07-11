local Op = require('fibers.atoms.op')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Interest = require('fibers.kernel.interest')
local Validity = require('fibers.kernel.validity')
local Common = require('fibers.atoms.external_common')

local pack_ = Op._pack
local Clock = {}
Clock.__index = Clock
local Kind = { name = 'clock' }

function Clock.new(name)
  return Common.new('clock', Clock, Kind, { name = name or 'clock' }, Validity.clock)
end

function Kind.eval(clock, payload, ctx)
  if payload.op ~= 'until' then error('clock resources support at_op', 2) end
  local deadline = payload.deadline
  local now = ctx and ctx.now and ctx:now() or 0
  if now >= deadline then return Result.ready(Proposal.new(pack_(true, now))) end
  local frontier = clock._validity:before_frontier(deadline)
  if ctx and ctx.before then ctx:before(clock, deadline)
  else clock._validity:observe_before(ctx, deadline) end
  ctx:add({ kind = 'clock-before', resource = clock, deadline = deadline, frontier = frontier, stamp = frontier.gen })
  return ctx:retry('clock-before-deadline', Interest.timer(deadline, clock, frontier))
end

function Kind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
  out.needs_overlay = false
end

function Clock:at_op(deadline)
  return Op._resource(self, Kind, { op = 'until', deadline = deadline })
end

Clock.Kind = Kind
return Clock
