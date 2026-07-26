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
local Host = require('fibers.host')
local SimulatedHost = require('examples.support.simulated_host')
local socket = require('fibers.socket')

fibers.run(function(scope)
  local listener = assert(socket.listen_inet('127.0.0.1', 0))
  local address = listener:local_address()

  local client = scope:spawn(function()
    local dial = assert(socket.dial_inet(address.host, address.port))
    local connection = assert(dial:result())
    connection:write('ping\n')
    assert(connection:read_line() == 'pong')
    connection:close('client complete')
  end, 'client')

  local connection = assert(listener:accept())
  assert(connection:read_line() == 'ping')
  connection:write('pong\n')
  connection:flush()
  connection:close('server complete')
  client:await()
  listener:close('example complete')
end, { host = SimulatedHost.new({ sockets = true }) })

print('socket echo: ok')
