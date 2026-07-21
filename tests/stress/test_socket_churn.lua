package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local socket = require('fibers.socket')
local ManualHost = require('fibers.host.manual')

local count = tonumber(os.getenv('FIBERS_STRESS_SOCKET_CYCLES')) or 24
local report = fibers.try_run(function(scope)
  local listener = assert(socket.listen_inet('127.0.0.1', 0, { accept_capacity = 8 }))
  local address = listener:local_address()
  local server = scope:spawn(function()
    for i = 1, count do
      local connection = assert(listener:accept())
      local byte = assert(connection:read(1))
      connection:write(byte)
      connection:flush()
      connection:close('stress server complete')
    end
  end, 'socket-stress-server')

  for i = 1, count do
    local dial = socket.dial(address)
    local connection = assert(dial:result())
    local byte = string.char(64 + ((i - 1) % 26) + 1)
    connection:write(byte)
    connection:flush()
    assert(connection:read(1) == byte)
    connection:close('stress client complete')
  end

  server:await()
  listener:close('stress complete')
end, {
  host = ManualHost.new({ sockets = true, pipes = true }),
  max_iterations = 200000,
})
assert(report.ok, tostring(report.primary or report.error))
print('tests/stress/test_socket_churn.lua: ok')
