-- Atomic nixio host family.

local Family = require('fibers.host.family')
local Datagram = require('fibers.host.datagram_nixio')
local Fd = require('fibers.host.fd_nixio')
local NixioPoll = require('fibers.host.nixio_poll')
local Process = require('fibers.host.process_nixio')
local Resolver = require('fibers.host.resolver_nixio')
local Socket = require('fibers.host.socket_nixio')

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return Family.unsupported('fibers.host.nixio', 'requires nixio')
end

local function read_uptime()
  local file = io.open('/proc/uptime', 'r')
  if not file then
    return nil
  end
  local line = file:read('*l')
  file:close()
  return line and tonumber(line:match('^%s*(%S+)')) or nil
end

local function monotonic()
  return read_uptime() or nixio.gettime()
end

local function sleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return true
  end
  local deadline = monotonic() + seconds
  while true do
    local remaining = deadline - monotonic()
    if remaining <= 0 then
      return true
    end
    local sec = math.floor(remaining)
    local nsec = math.floor((remaining - sec) * 1e9 + 0.5)
    if nsec >= 1000000000 then
      sec, nsec = sec + 1, nsec - 1000000000
    end
    local ok, err, eno = nixio.nanosleep(sec, nsec)
    if not ok then
      local message = tostring(err or eno or '')
      if message ~= '' and message ~= 'EINTR' and message ~= 'interrupted system call' then
        return nil, 'nixio.nanosleep failed: ' .. message
      end
    end
  end
end

local function poll_key(key)
  if type(key) == 'table' then
    return key.handle or key.nixio or key
  end
  return key
end

local function poll(plan, timeout)
  local ready = NixioPoll.run(nixio, plan, timeout)
  if not ready then
    return nil, 'poll-interrupted'
  end
  return ready
end

return Family.polling({
  name = 'nixio',
  prefix = 'fibers.host.nixio',
  family = 'nixio',
  is_supported = function()
    return type(nixio.gettime) == 'function'
      and type(nixio.nanosleep) == 'function'
      and type(nixio.poll) == 'function'
      and type(nixio.poll_flags) == 'function'
  end,
  now = monotonic,
  sleep = sleep,
  poll = poll,
  poll_keys = { key_of = poll_key, fd_of = NixioPoll.descriptor_number },
  fd = Fd,
  socket = Socket,
  datagram = Datagram,
  resolver = Resolver,
  process = Process,
  datagram_truncation = false,
  capabilities = {
    process_exec_proof = false,
    process_pass_fds = false,
    process_close_fds = 'known',
    process_groups = 'session',
  },
})
