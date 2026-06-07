-- Synchronous rendezvous channel.

local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')
local DefaultOp = require('fibers.op')
local OpPack = DefaultOp._pack

local Channel = {}
Channel.__index = Channel

local ChannelKind = { name = 'channel' }
local next_id = 0

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
end

function ChannelKind.eval(channel, payload, ctx)
  local op = payload.op
  if op == 'get' then
    local ph = Candidate.new_ph()
    local c = Candidate.new(OpPack(ph))
    c.endpoints[#c.endpoints + 1] = { kind = 'rendezvous', primitive = 'channel', role = 'get', key = channel, ph = ph, origin = ctx.origin }
    return Result.cands({ c })
  elseif op == 'put' then
    local c = Candidate.new(OpPack(true))
    c.endpoints[#c.endpoints + 1] = { kind = 'rendezvous', primitive = 'channel', role = 'put', key = channel, value = payload.value, origin = ctx.origin }
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
  return setmetatable({ name = name or ('channel-' .. tostring(next_id)), _fibers_id = 'channel-' .. tostring(next_id), _fibers_kind = ChannelKind, _fibers_value = true }, Channel)
end

function Channel:get_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, ChannelKind, { op = 'get' })
end

Channel.recv_op = Channel.get_op

function Channel:put_op(a, b)
  local Op, value
  if is_op_module(a) then Op, value = a, b else Op, value = DefaultOp, a end
  return Op._resource(self, ChannelKind, { op = 'put', value = value })
end

Channel.send_op = Channel.put_op
Channel.Kind = ChannelKind
return Channel
