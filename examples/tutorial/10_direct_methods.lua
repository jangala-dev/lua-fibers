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
local file = require('fibers.file')
local socket = require('fibers.socket')

fibers.run(function()
  local reader, writer = file.pipe({ name = 'direct-example-pipe' })

  fibers.spawn(function()
    writer:write('hello\n')
    writer:close()
  end)

  assert(reader:read_line() == 'hello')
  reader:close()

  local listener = assert(socket.listen_inet('127.0.0.1', 0))
  local address = listener:local_address()

  local client = fibers.spawn(function()
    local dial = assert(socket.dial_inet(address.host, address.port))
    local connection = assert(dial:result())
    connection:write('ping\n')
    assert(connection:read_line() == 'pong')
    connection:close()
  end)

  local connection = assert(listener:accept())
  assert(connection:read_line() == 'ping')
  connection:write('pong\n')
  connection:flush()
  connection:close()
  client:await()
  listener:close()
end, { host = Host.manual({ pipes = true, sockets = true }) })

print('examples/tutorial/10_direct_methods.lua: ok')
