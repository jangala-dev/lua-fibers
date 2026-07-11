local Op = require('fibers.atoms.op')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Validity = require('fibers.kernel.validity')
local Common = require('fibers.atoms.external_common')

local pack_ = Op._pack
local Readiness = {}
Readiness.__index = Readiness
local Kind = { name = 'readiness' }

local function mode(value, level)
  return Common.normalise_readiness_mode(value, level)
end

local function deliver(readiness, ...)
  local n, first = select('#', ...), ...
  local selected, value
  if type(first) == 'string' then
    selected, value = mode(first, 3), select(2, ...)
    if n <= 1 then value = true end
  else
    selected, value = mode(readiness.mode, 3), first
    if n == 0 then value = true end
  end
  readiness._validity:set(selected, value ~= false and value ~= nil, 'readiness changed')
end

local function clear(readiness, selected)
  if selected == nil then readiness._validity:clear(nil, 'readiness cleared')
  else readiness._validity:clear(mode(selected, 3), 'readiness cleared') end
end

function Readiness.new(key, initial_mode, name)
  local readiness = Common.new('readiness', Readiness, Kind, {
    key = key,
    mode = mode(initial_mode or 'read', 3),
    name = name,
  }, Validity.level)
  readiness._fibers_external_deliver = deliver
  readiness._fibers_external_clear = clear
  return readiness
end

function Kind.eval(readiness, payload, ctx)
  if payload.op ~= 'wait' then error('readiness resources support readiness_op', 2) end
  local selected = mode(payload.mode or readiness.mode or 'read', 3)
  local key = payload.key or readiness.key
  if readiness._validity:get(ctx, selected) then
    return Result.ready(Proposal.new(pack_(true, key, selected)))
  end
  local frontier = readiness._validity:frontier_for('readiness', selected)
  ctx:add({ kind = 'readiness-absent', resource = readiness, mode = selected, frontier = frontier, stamp = frontier.gen })
  return ctx:retry('readiness-not-set', Common.interest(ctx, readiness,
    tostring(selected) .. ':' .. tostring(key),
    { external_kind = 'readiness', key = key, mode = selected }))
end

function Kind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
  out.needs_overlay = false
end

function Readiness:wait_op()
  return self:readiness_op(self.mode or 'read')
end

function Readiness:readiness_op(selected)
  return Op._resource(self, Kind, { op = 'wait', key = self.key, mode = mode(selected or self.mode or 'read', 3) })
end

function Readiness:readable_op() return self:readiness_op('read') end
function Readiness:writable_op() return self:readiness_op('write') end

Readiness.Kind = Kind
return Readiness
