-- Host adapter using luaposix poll/time.
--
-- Optional backend.  This uses posix.time.clock_gettime/nanosleep for time and
-- posix.poll.poll for readiness waits.  It has no persistent kernel state;
-- readiness registrations are rebuilt from the runtime's current waits on each
-- block call.

local Host = require('fibers.host')

local ok_poll, poll_mod = pcall(require, 'posix.poll')
local ok_time, ptime = pcall(require, 'posix.time')
local ok_errno, errno = pcall(require, 'posix.errno')

if not ok_poll or type(poll_mod) ~= 'table'
  or not ok_time or type(ptime) ~= 'table'
  or not ok_errno or type(errno) ~= 'table'
then
  return {
    is_supported = function() return false end,
    new = function() error('fibers.host.luaposix requires posix.poll, posix.time and posix.errno', 2) end,
  }
end

local Posix = {}
Posix.__index = Posix

local CLOCK_MONOTONIC = ptime.CLOCK_MONOTONIC
local poll_fn = poll_mod.poll

local function ts_to_seconds(ts)
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

local function monotonic()
  local ts, err = ptime.clock_gettime(CLOCK_MONOTONIC)
  if not ts then error('posix.clock_gettime(CLOCK_MONOTONIC) failed: ' .. tostring(err), 2) end
  return ts_to_seconds(ts)
end

local function nanosleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return true end
  local sec = math.floor(seconds)
  local nsec = math.floor((seconds - sec) * 1e9 + 0.5)
  if nsec >= 1000000000 then sec = sec + 1; nsec = nsec - 1000000000 end
  local req = { tv_sec = sec, tv_nsec = nsec }
  while true do
    local ok, err, eno, rem = ptime.nanosleep(req)
    if ok then return true end
    if eno == errno.EINTR and rem then
      req = rem
    else
      return nil, 'posix.nanosleep failed: ' .. tostring(err or eno)
    end
  end
end

local function collect_readiness(waits)
  local fds, by_fd, unsupported = {}, {}, false
  local readiness = Host.readiness_waits(waits)
  for i = 1, #readiness do
    local w = readiness[i]
    local key = w.readiness_key
    local fd = tonumber(key)
    if not fd then
      unsupported = true
    else
      local rec = by_fd[fd]
      if not rec then
        rec = { fd = fd, events = {}, waits = {} }
        by_fd[fd] = rec
        fds[fd] = { events = rec.events }
      end
      local mode = w.mode or 'read'
      if mode == 'write' or mode == 'wr' then rec.events.OUT = true else rec.events.IN = true end
      rec.waits[#rec.waits + 1] = w
    end
  end
  return fds, by_fd, unsupported
end

function Posix.is_supported()
  return type(poll_fn) == 'function'
    and type(ptime.clock_gettime) == 'function'
    and type(ptime.nanosleep) == 'function'
    and CLOCK_MONOTONIC ~= nil
end

function Posix.new(opts)
  opts = opts or {}
  if not Posix.is_supported() then error('fibers.host.luaposix: required luaposix functions are unavailable', 2) end
  local self = setmetatable({
    kind = 'luaposix',
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
  }, Posix)
  self.now = function(_rt) return monotonic() end
  return self
end

function Posix:sleep(seconds)
  return nanosleep(seconds)
end

function Posix:block(rt, waits, status, _opts)
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local fds, by_fd, unsupported = collect_readiness(waits)

  if unsupported then
    if self.on_unsupported then self.on_unsupported(waits, status) end
    return nil, 'unsupported-readiness-key'
  end

  local have_fd = false
  for _ in pairs(by_fd) do have_fd = true; break end

  if not have_fd then
    if deadline ~= nil then
      local delay = Host.delay_until(rt, deadline) or 0
      if delay > 0 then
        if self.on_wait then self.on_wait(deadline, delay, waits, status) end
        local ok, err = self:sleep(delay)
        if not ok then error(err, 2) end
        if self.on_wake then self.on_wake(deadline, waits, status) end
      end
      return true, 'time'
    end
    if self.on_unsupported then self.on_unsupported(waits, status) end
    return nil, 'unsupported-waits'
  end

  local timeout_ms = Host.timeout_ms(rt, deadline)
  local nready, err, eno = poll_fn(fds, timeout_ms)
  if nready == nil then
    if eno == errno.EINTR then return true, 'poll-interrupted' end
    error(tostring(err or eno or 'posix.poll failed'), 2)
  end

  local delivered = false
  if nready > 0 then
    for fd, info in pairs(fds) do
      local re = info.revents
      if re then
        local rd = re.IN or re.HUP or re.ERR or re.NVAL
        local wr = re.OUT or re.ERR or re.NVAL
        local rec = by_fd[fd]
        if rec then
          for i = 1, #rec.waits do
            local w = rec.waits[i]
            local mode = w.mode or 'read'
            if (mode == 'write' or mode == 'wr') and wr then
              rt:arrive(w.source, 'write', true); delivered = true
            elseif mode ~= 'write' and mode ~= 'wr' and rd then
              rt:arrive(w.source, 'read', true); delivered = true
            end
          end
        end
      end
    end
  end

  if delivered then return true, 'readiness' end
  if deadline ~= nil and rt:now() >= deadline then return true, 'time' end
  return true, 'poll'
end

function Posix:close()
  -- posix.poll is stateless; there is no persistent host fd to close.
end

return Posix
