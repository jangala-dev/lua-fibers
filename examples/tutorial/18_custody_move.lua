package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A protocol decision can move custody in the same transaction as the state
-- changes and communication which justify the transfer.

local fibers = require('fibers')
local Scalar = require('fibers.resource.scalar')
local Scope = require('fibers.scope')
local Stream = require('fibers.stream')

local client, server = Stream.memory_pair({ name = 'protocol-stream', capacity = 128 })
local negotiator = Scope.new('negotiator')
local responder = Scope.new('responder')
local protocol = Scalar.new('unknown', 'protocol')
local reply

local result = fibers.try_run(function()
  fibers.perform(negotiator:raw_region():admit_op(server))
  fibers.perform(client:writer():write_op('PING\n'))

  fibers.perform(server:reader():read_line_op():and_then(function(line)
    if line ~= 'PING' then
      return server:close_op('unsupported protocol')
    end
    return protocol
      :write_op('ping')
      :and_then(function()
        return negotiator:move_op(server, responder)
      end)
      :and_then(function()
        return server:writer():write_op('PONG\n')
      end)
  end))

  reply = fibers.perform(client:reader():read_line_op())
end)

assert(result.ok)
assert(protocol.value == 'ping')
assert(reply == 'PONG')
assert(server.owner == responder:raw_region())
print('protocol:', protocol.value, 'reply:', reply, 'owner:', server.owner.name)
