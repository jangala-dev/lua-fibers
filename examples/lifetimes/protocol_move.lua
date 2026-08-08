package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')
local Scope = require('fibers.scope')
local Stream = require('fibers.stream')

local client, server = Stream.memory_pair({ label = 'negotiated-stream', capacity = 128 })
local negotiator = Scope.new():label('negotiator')
local responder = Scope.new():label('responder')
local protocol = Cell.new('unknown'):label('protocol-state')
local reply, responder_has_custody, final_protocol

local function negotiate_op(stream)
  return stream:reader():read_line_op():and_then(Op.guard(function(line)
    if line == 'PING' then
      return protocol
        :write_op('ping')
        :and_then(negotiator:move_op(stream, responder))
        :and_then(stream:writer():write_op('PONG\n'))
        :map(function()
          return 'ping'
        end)
    end
    return stream
      :writer()
      :write_op('BAD\n')
      :and_then(stream:close_op('bad protocol'))
      :map(function()
        return nil, 'bad_protocol'
      end)
  end))
end

local st = fibers.try_run(function()
  fibers.perform(negotiator:admit_op(server))
  fibers.perform(client:writer():write_op('PING\n'))
  fibers.perform(negotiate_op(server))
  reply = fibers.perform(client:reader():read_line_op())
  responder_has_custody = fibers.perform(responder:has_custody_op(server))
  final_protocol = protocol:read()
end).runtime_status

assert(st.tag == 'found')
assert(final_protocol == 'ping')
assert(reply == 'PONG')
assert(responder_has_custody)
print('examples/lifetimes/protocol_move.lua: ok')
