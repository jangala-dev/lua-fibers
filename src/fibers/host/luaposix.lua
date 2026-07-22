-- Atomic luaposix host family.

local Family = require('fibers.host.family')
local Datagram = require('fibers.host.datagram_luaposix')
local Fd = require('fibers.host.fd_luaposix')
local Process = require('fibers.host.process_luaposix')
local Resolver = require('fibers.host.resolver_luaposix')
local Socket = require('fibers.host.socket_luaposix')

local ok_poll, poll_mod = pcall(require, 'posix.poll')
local ok_time, ptime = pcall(require, 'posix.time')
local ok_errno, errno = pcall(require, 'posix.errno')
if
  not ok_poll
  or type(poll_mod) ~= 'table'
  or not ok_time
  or type(ptime) ~= 'table'
  or not ok_errno
  or type(errno) ~= 'table'
then
  return Family.unsupported('fibers.host.luaposix', 'requires posix.poll, posix.time and posix.errno')
end

local CLOCK_MONOTONIC = ptime.CLOCK_MONOTONIC

local function monotonic()
  local ts, err = ptime.clock_gettime(CLOCK_MONOTONIC)
  if not ts then
    error('posix.clock_gettime(CLOCK_MONOTONIC) failed: ' .. tostring(err), 2)
  end
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

local function sleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return true
  end
  local sec = math.floor(seconds)
  local nsec = math.floor((seconds - sec) * 1e9 + 0.5)
  if nsec >= 1000000000 then
    sec, nsec = sec + 1, nsec - 1000000000
  end
  local req = { tv_sec = sec, tv_nsec = nsec }
  while true do
    local ok, err, eno, rem = ptime.nanosleep(req)
    if ok then
      return true
    end
    if eno == errno.EINTR and rem then
      req = rem
    else
      return nil, 'posix.nanosleep failed: ' .. tostring(err or eno)
    end
  end
end

local function fd_of(key)
  if type(key) == 'number' then
    return key
  end
  if type(key) == 'string' and tonumber(key) then
    return tonumber(key)
  end
  if type(key) == 'table' then
    if type(key.fd) == 'number' then
      return key.fd
    end
    if type(key.fileno) == 'function' then
      local ok, fd = pcall(key.fileno, key)
      if ok and fd ~= nil then
        return tonumber(fd)
      end
    end
  end
  return tonumber(key)
end

local function poll(plan, timeout)
  local fds = {}
  for i = 1, #plan.records do
    local record = plan.records[i]
    local events = {}
    if record.read then
      events.IN = true
    end
    if record.write then
      events.OUT = true
    end
    fds[record.fd] = { events = events }
  end
  local nready, err, eno = poll_mod.poll(fds, timeout)
  if nready == nil then
    if eno == errno.EINTR then
      return nil, 'poll-interrupted'
    end
    error(tostring(err or eno or 'posix.poll failed'), 2)
  end
  local ready = {}
  if nready > 0 then
    for fd, info in pairs(fds) do
      local events = info.revents
      if events then
        ready[#ready + 1] = {
          record = plan.by_fd[fd],
          read = events.IN or events.HUP or events.ERR or events.NVAL,
          write = events.OUT or events.ERR or events.NVAL,
        }
      end
    end
  end
  return ready
end

return Family.polling({
  name = 'luaposix',
  prefix = 'fibers.host.luaposix',
  family = 'numeric-fd',
  is_supported = function()
    return type(poll_mod.poll) == 'function'
      and type(ptime.clock_gettime) == 'function'
      and type(ptime.nanosleep) == 'function'
      and CLOCK_MONOTONIC ~= nil
  end,
  now = monotonic,
  sleep = sleep,
  poll = poll,
  poll_keys = { key_of = fd_of, fd_of = fd_of },
  fd = Fd,
  socket = Socket,
  datagram = Datagram,
  resolver = Resolver,
  process = Process,
  datagram_truncation = false,
})
