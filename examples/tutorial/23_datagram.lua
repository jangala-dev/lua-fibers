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
local socket = require('fibers.socket')
local SimulatedHost = require('examples.support.simulated_host')

local host = SimulatedHost.new({ datagrams = true })

fibers.run(function()
  local client = assert(socket.udp_ipv4('127.0.0.1', 0))
  local server = assert(socket.udp_ipv4('127.0.0.1', 0))

  client:send_to('status?', server:local_address())
  client:flush()

  local request = assert(server:receive_from())
  assert(request.data == 'status?')

  server:send_to('ready', request.peer)
  server:flush()

  local reply = assert(client:receive_from({ max_size = 1024 }))
  assert(reply.data == 'ready')

  client:close('example complete')
  server:close('example complete')
end, { host = host })
