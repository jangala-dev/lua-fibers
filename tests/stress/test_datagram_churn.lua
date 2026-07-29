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

if os.getenv('FIBERS_MACHINE') == 'reference' then
  return { status = 'skip', reason = 'native churn uses the production evaluator' }
end

local ok_mod, LinuxHost = pcall(require, 'fibers.io.luajit_linux')
if not ok_mod or not LinuxHost.is_supported() then
  return { status = 'skip', reason = 'LuaJIT FFI Linux datagram host unavailable' }
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

local cycles = tonumber(os.getenv('FIBERS_STRESS_DATAGRAM_CYCLES')) or 24
local host = LinuxHost.new()
collectgarbage('collect')
local before = linux_fd_count()
local report = fibers.try_run(function()
  local receiver = assert(socket.udp_ipv4('127.0.0.1', 0, { receive_capacity = 4 }))
  local target = receiver:local_address()
  for i = 1, cycles do
    local sender = assert(socket.udp_ipv4('127.0.0.1', 0))
    local payload = string.char(64 + ((i - 1) % 26) + 1)
    sender:send_to(payload, target)
    sender:flush()
    assert(assert(receiver:receive_from()).data == payload)
    sender:close('churn complete')
    sender:closed()
  end
  receiver:close('churn complete')
  receiver:closed()
end, { host = host, max_iterations = 200000 })
assert(report.ok, tostring(report.primary or report.error))
collectgarbage('collect')
local after = linux_fd_count()
if before and after then
  assert(after == before, 'datagram churn leaked descriptors')
end
host:close()
print('tests/stress/test_datagram_churn.lua: ok')
