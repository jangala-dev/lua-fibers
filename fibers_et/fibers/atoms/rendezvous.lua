-- Synchronous rendezvous point.
--
-- Rendezvous primitives pass values. They do not inspect values with user code;
-- selection belongs in the Op algebra.

local Result = require('fibers.kernel.resources.result')
local Resolution = require('fibers.kernel.resources.resolution')
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')
local OpPack = Op._pack

local Rendezvous = {}
Rendezvous.__index = Rendezvous

local RendezvousKind = { name = 'rendezvous' }
local next_id = 0

function RendezvousKind.eval(_rendezvous, payload, _ctx)
  local op = payload.op
  if op == 'get' then
    return Result.premise({ role = 'get' })
  elseif op == 'put' then
    return Result.premise({ role = 'put', value = payload.value })
  end
  error('unknown rendezvous command ' .. tostring(op), 2)
end

function RendezvousKind.resolve_premises(_rendezvous, premises, ctx)
  local out = {}
  for gi = 1, #premises do
    local g = premises[gi]
    if g.request and g.request.role == 'get' then
      for pi = 1, #premises do
        local p = premises[pi]
        if p.request and p.request.role == 'put' and ctx:compatible(g, p) then
          out[#out + 1] = {
            ids = { g.id, p.id },
            results = {
              [g.id] = OpPack(p.request.value),
              [p.id] = OpPack(true),
            },
          }
        end
      end
    end
  end
  local frontier = _rendezvous._validity_opaque and _rendezvous._validity_opaque:frontier_for() or nil
  return Resolution.exhaustive_after(out, ctx, {
    { kind = 'rendezvous-solutions-exhausted', rendezvous = _rendezvous, frontier = frontier, stamp = frontier and frontier.gen or nil },
  })
end


function RendezvousKind.summary(_payload, out)
  out.endpoints = true
  out.closed = false
  out.needs_overlay = false
end

function Rendezvous.new(name)
  next_id = next_id + 1
  local id = 'rendezvous-' .. tostring(next_id)
  local rendezvous = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = RendezvousKind }, Rendezvous)
  rendezvous._validity_opaque = Validity.epoch((rendezvous.name or id) .. ':offers')
  return rendezvous
end

function Rendezvous:get_op()
  return Op._resource(self, RendezvousKind, { op = 'get' })
end


function Rendezvous:put_op(value)
  return Op._resource(self, RendezvousKind, { op = 'put', value = value })
end

Rendezvous.Kind = RendezvousKind
return Rendezvous
