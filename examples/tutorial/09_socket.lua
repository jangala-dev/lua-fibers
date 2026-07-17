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
local socket = require('fibers.socket')

fibers.run(function()
  local listener = assert(fibers.perform(socket.listen_inet_op('127.0.0.1', 0, { name = 'echo-listener' })))
  local address = listener:local_address()

  local client = fibers.spawn(function()
    local dial = fibers.perform(socket.dial_inet_op(address.host, address.port))
    local connection = assert(fibers.perform(dial:result_op()))
    fibers.perform(connection:write_op('ping\n'))
    assert(fibers.perform(connection:read_line_op()) == 'pong')
    fibers.perform(connection:close_op())
  end, 'client')

  local connection = assert(fibers.perform(listener:accept_op()))
  assert(fibers.perform(connection:read_line_op()) == 'ping')
  fibers.perform(connection:write_op('pong\n'))
  fibers.perform(connection:flush_op())
  fibers.perform(connection:close_op())
  fibers.perform(client:await_op())
  fibers.perform(listener:close_op())
end, { host = Host.manual({ sockets = true, auto_advance_time = false }) })

print('examples/tutorial/09_socket.lua: ok')
