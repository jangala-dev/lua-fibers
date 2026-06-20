-- Synchronous rendezvous channel.
--
-- Channel primitives pass values. They do not inspect values with user code;
-- selection belongs in the Op algebra.

local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Op = require('fibers.base.op')
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
  error('unknown channel operation ' .. tostring(op), 2)
end

function ChannelKind.summary(_payload, out)
  out.endpoints = true
  out.closed = false
end

function Channel.new(name)
  next_id = next_id + 1
  return setmetatable({ name = name or ('channel-' .. tostring(next_id)), _fibers_id = 'channel-' .. tostring(next_id), _fibers_kind = ChannelKind }, Channel)
end

function Channel:get_op()
  return Op._resource(self, ChannelKind, { op = 'get' })
end


function Channel:put_op(value)
  return Op._resource(self, ChannelKind, { op = 'put', value = value })
end

Channel.Kind = ChannelKind
return Channel
