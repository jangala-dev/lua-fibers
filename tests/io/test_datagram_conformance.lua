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
local SimulatedHost = require('tests.support.simulated_host')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function linux_fd_count()
  local stat = io.open('/proc/self/stat', 'r')
  if not stat then
    return nil
  end
  local line = stat:read('*l')
  stat:close()
  local pid = line and string.match(line, '^(%d+)') or nil
  if not pid or type(io.popen) ~= 'function' then
    return nil
  end
  local pipe = io.popen('ls -1 /proc/' .. pid .. '/fd 2>/dev/null')
  if not pipe then
    return nil
  end
  local count = 0
  for _ in pipe:lines() do
    count = count + 1
  end
  pipe:close()
  return count
end

local function run_exchange(label, host, family)
  local report = fibers.try_run(function()
    local left
    local right
    if family == 'inet6' then
      left = assert(socket.udp_ipv6('::1', 0, { name = label .. ':left' }))
      right = assert(socket.udp_ipv6('::1', 0, { name = label .. ':right' }))
    else
      left = assert(socket.udp_ipv4('127.0.0.1', 0, { name = label .. ':left' }))
      right = assert(socket.udp_ipv4('127.0.0.1', 0, { name = label .. ':right' }))
    end

    assert(left:send_to('', right:local_address()))
    assert(left:send_to('abcdef', right:local_address()))
    assert(left:flush())

    local empty = assert(right:receive_from())
    assert_eq(empty.data, '', label .. ' zero-length payload')
    assert_eq(empty.peer.port, left:local_address().port, label .. ' source port')

    local limited = assert(right:receive_from({ max_size = 3 }))
    assert_eq(limited.data, 'abc', label .. ' limited payload')
    assert(limited.truncated == true)
    assert_eq(limited.original_size, 6, label .. ' original size')

    right:send_to('reply', left:local_address())
    right:flush()
    assert_eq(assert(left:receive_from()).data, 'reply', label .. ' reverse payload')

    left:close(label .. ' complete')
    right:close(label .. ' complete')
    assert(left:closed())
    assert(right:closed())
  end, { host = host, max_iterations = 50000 })
  assert(report.ok, label .. ': ' .. tostring(report.primary or report.error))
end

run_exchange('manual-ipv4', SimulatedHost.new({ datagrams = true }), 'inet4')
run_exchange('manual-ipv6', SimulatedHost.new({ datagrams = true }), 'inet6')

print('tests/io/test_datagram_conformance.lua: ok')
