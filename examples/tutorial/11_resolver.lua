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

local host = Host.manual({
  sockets = true,
  resolver_records = {
    ['echo.test'] = {
      { kind = 'inet6', host = '::1' },
      { kind = 'inet4', host = '127.0.0.1' },
    },
  },
})

fibers.run(function(scope)
  local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
  local local_address = listener:local_address()
  for _, address in ipairs(host.resolver_records['echo.test']) do
    address.port = local_address.port
  end

  local server = scope:spawn(function()
    local connection = assert(listener:accept())
    assert(connection:read_line() == 'ping')
    connection:write('pong\n')
    connection:flush()
    connection:close('server complete')
  end, 'resolver-example-server')

  local query = socket.resolve_name('echo.test', local_address.port, {
    family = 'inet4',
  })
  local addresses, resolve_err = query:result()
  assert(addresses, resolve_err)

  local dial = socket.dial(addresses[1])
  local connection, dial_err = dial:result()
  assert(connection, dial_err)
  connection:write('ping\n')
  connection:flush()
  assert(connection:read_line() == 'pong')
  connection:close('client complete')

  server:await()
  listener:close('example complete')
end, { host = host })

print('examples/tutorial/11_resolver.lua: ok')
