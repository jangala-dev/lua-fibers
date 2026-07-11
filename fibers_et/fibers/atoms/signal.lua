local Op = require('fibers.atoms.op')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Validity = require('fibers.kernel.validity')
local Common = require('fibers.atoms.external_common')

local pack_ = Op._pack
local Signal = {}
Signal.__index = Signal
local Kind = { name = 'signal' }

local function deliver(signal, ...)
  signal._validity:set(pack_(...), 'signal arrived')
end

local function clear(signal)
  signal._validity:clear('signal cleared')
end

function Signal.new(name)
  local signal = Common.new('signal', Signal, Kind, { name = name }, Validity.signal)
  signal._fibers_external_deliver = deliver
  signal._fibers_external_clear = clear
  return signal
end

function Kind.eval(signal, payload, ctx)
  if payload.op ~= 'wait' then error('signal resources support wait_op', 2) end
  local values, ready = signal._validity:get(ctx)
  if ready then return Result.ready(Proposal.new(values or pack_(true))) end
  local frontier = signal._validity:frontier_for('signal.state')
  ctx:add({ kind = 'signal-absent', resource = signal, frontier = frontier, stamp = frontier.gen })
  return ctx:retry('signal-not-ready', Common.interest(ctx, signal, payload.interest or 'ready', { external_kind = 'signal' }))
end

function Kind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
  out.needs_overlay = false
end

function Signal:wait_op()
  return Op._resource(self, Kind, { op = 'wait', interest = 'ready' })
end

Signal.Kind = Kind
return Signal
