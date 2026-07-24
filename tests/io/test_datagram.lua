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
local Op = require('fibers.op')
local socket = require('fibers.socket')
local ManualHost = require('fibers.host.manual')
local HostError = require('fibers.host.error')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

-- A losing construction option must perform no host acquisition.
local acquisitions = 0
local losing_host = ManualHost.new({ datagrams = true })
local create = losing_host.create_datagram
losing_host.create_datagram = function(self, ...)
  acquisitions = acquisitions + 1
  return create(self, ...)
end
fibers.run(function()
  local value = fibers.perform(Op.always('winner'):or_else(socket.udp_ipv4_op('127.0.0.1', 0)))
  assert_eq(value, 'winner')
end, { host = losing_host })
assert_eq(acquisitions, 0, 'losing datagram option must remain inert')

local host = ManualHost.new({ datagrams = true })
local report = fibers.try_run(function()
  local sender = assert(socket.udp_ipv4('127.0.0.1', 0, {
    send_capacity = 2,
  }))
  local receiver = assert(socket.udp_ipv4('127.0.0.1', 0, {
    receive_capacity = 1,
  }))

  assert(sender:send_to('', receiver:local_address()))
  assert(sender:send_to('abcdef', receiver:local_address()))

  local first = assert(receiver:receive_from())
  assert_eq(first.data, '', 'zero-length datagram must be preserved')
  assert_eq(first.peer.port, sender:local_address().port, 'source port must be preserved')

  local second = assert(receiver:receive_from({ max_size = 3 }))
  assert_eq(second.data, 'abc', 'caller receive limit should trim the delivered message')
  assert(second.truncated == true)
  assert_eq(second.original_size, 6)
  assert(sender:flush())

  local mismatch_ok, mismatch_err =
    sender:send_to('wrong family', socket.ipv6_address('::1', receiver:local_address().port))
  assert(mismatch_ok == nil)
  assert(HostError.is(mismatch_err, 'invalid_argument'))

  sender:close('sender complete')
  receiver:close('receiver complete')
  assert(sender:closed())
  assert(receiver:closed())
end, { host = host, verify_dependencies = true })
assert(report.ok, tostring(report.primary or report.error))

-- Dropping a packet in the deterministic transport still represents successful
-- kernel admission and therefore does not make flush fail.
local drop_host = ManualHost.new({
  datagrams = true,
  datagram_send = function()
    return false
  end,
})
fibers.run(function()
  local sender = assert(socket.udp_ipv4('127.0.0.1', 0))
  assert(sender:send_to('lost', socket.ipv4_address('127.0.0.1', 9)))
  assert(sender:flush())
  sender:close()
end, { host = drop_host })

-- Closing a socket makes blocked and future receives terminate with a structured
-- closed result rather than hanging.
local close_host = ManualHost.new({ datagrams = true })
fibers.run(function(scope)
  local receiver = assert(socket.udp_ipv4('127.0.0.1', 0))
  local waiter = scope:spawn(function()
    local packet, err = receiver:receive_from()
    assert(packet == nil)
    assert(HostError.is(err, 'closed'))
  end, 'datagram-close-waiter')
  fibers.spawn(function()
    receiver:close('test close')
  end)
  waiter:await()
end, { host = close_host })

print('tests/io/test_datagram.lua: ok')
