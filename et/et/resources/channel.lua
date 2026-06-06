local Candidate = require('et.algebra.candidate')
local Result = require('et.algebra.result')
local OpPack = require('et.op')._pack

local Channel = {}
Channel.__index = Channel

local ChannelKind = { name = 'channel' }
local next_id = 0

function ChannelKind.eval(channel, payload, ctx)
  local op = payload.op
  if op == 'get' then
    local ph = Candidate.new_ph()
    local c = Candidate.new(OpPack(ph))
    c.endpoints[#c.endpoints + 1] = {
      kind = 'rendezvous',
      primitive = 'channel',
      role = 'get',
      key = channel,
      ph = ph,
      origin = ctx.origin,
    }
    return Result.cands({ c })
  elseif op == 'put' then
    local c = Candidate.new(OpPack(true))
    c.endpoints[#c.endpoints + 1] = {
      kind = 'rendezvous',
      primitive = 'channel',
      role = 'put',
      key = channel,
      value = payload.value,
      origin = ctx.origin,
    }
    return Result.cands({ c })
  end
  error('unknown channel operation ' .. tostring(op), 2)
end

function ChannelKind.summary(_payload, out)
  out.endpoints = true
  out.closed = false
end

function Channel.new(name)
  next_id = next_id + 1
  return setmetatable({ name = name or ('channel-' .. tostring(next_id)), _et_id = next_id, _et_kind = ChannelKind }, Channel)
end

function Channel:get_op(Op)
  return Op._resource(self, ChannelKind, { op = 'get' })
end

function Channel:put_op(Op, value)
  return Op._resource(self, ChannelKind, { op = 'put', value = value })
end

Channel.Kind = ChannelKind

return Channel
