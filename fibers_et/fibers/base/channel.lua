-- Synchronous rendezvous channel.
--
-- Channel primitives pass values. They do not inspect values with user code;
-- selection belongs in the Op algebra.

local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Op = require('fibers.base.op')
local Validity = require('fibers.kernel.validity')
local OpPack = Op._pack

local Channel = {}
Channel.__index = Channel

local ChannelKind = { name = 'channel' }
local next_id = 0

function ChannelKind.eval(channel, payload, ctx)
  local op = payload.op
  if op == 'get' then
    local ph = Proposal.new_ph()
    local c = Proposal.new(OpPack(ph))
    c.endpoints[#c.endpoints + 1] = { kind = 'rendezvous', primitive = 'channel', role = 'get', key = channel, ph = ph, origin = ctx.origin }
    return Result.ready(c)
  elseif op == 'put' then
    local c = Proposal.new(OpPack(true))
    c.endpoints[#c.endpoints + 1] = { kind = 'rendezvous', primitive = 'channel', role = 'put', key = channel, value = payload.value, origin = ctx.origin }
    return Result.ready(c)
  end
  error('unknown channel command ' .. tostring(op), 2)
end


function ChannelKind.absence(channel, payload, ctx)
  local frontier = channel._validity_opaque and channel._validity_opaque:frontier_for() or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  if ctx and ctx.add then ctx:add({ kind = 'channel-absent', channel = channel, role = payload and payload.op, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
  return true
end

function ChannelKind.summary(_payload, out)
  out.endpoints = true
  out.closed = false
end

function Channel.new(name)
  next_id = next_id + 1
  local id = 'channel-' .. tostring(next_id)
  local channel = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = ChannelKind }, Channel)
  channel._validity_opaque = Validity.epoch((channel.name or id) .. ':offers')
  return channel
end

function Channel:get_op()
  return Op._resource(self, ChannelKind, { op = 'get' })
end


function Channel:put_op(value)
  return Op._resource(self, ChannelKind, { op = 'put', value = value })
end

Channel.Kind = ChannelKind
return Channel
