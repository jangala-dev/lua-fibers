package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Stream = fibers.Stream
local Lifetime = fibers.Lifetime

local client, server = Stream.memory_pair({ name = 'negotiated-stream', capacity = 128 })
local negotiator = Lifetime.new('negotiator')
local responder = Lifetime.new('responder')
local protocol = fibers.Cell.new('unknown', 'protocol-state')
local reply

local function negotiate_op(stream)
  return stream:read_line_op():and_then(function(line)
    if line == 'PING' then
      return protocol:write_op('ping'):and_then(function()
        return negotiator:handoff_op(stream, responder)
      end):and_then(function()
        return stream:write_op('PONG\n')
      end):map(function()
        return 'ping'
      end)
    end
    return stream:write_op('BAD\n'):and_then(function()
      return stream:close_op('bad protocol')
    end):map(function()
      return nil, 'bad_protocol'
    end)
  end)
end

local st = fibers.run(function()
  fibers.perform(negotiator:raw_region():admit_op(server))
  fibers.perform(client:write_op('PING\n'))
  fibers.perform(negotiate_op(server))
  reply = fibers.perform(client:read_line_op())
end)

assert(st.tag == 'found')
assert(protocol.value == 'ping')
assert(reply == 'PONG')
assert(server.owner == responder:raw_region())
print('examples/10_stream_protocol_handoff.lua: ok')
