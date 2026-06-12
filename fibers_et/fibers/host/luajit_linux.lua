-- Linux host adapter using LuaJIT FFI.
--
-- This module is optional.  Requiring it under ordinary Lua succeeds, but
-- is_supported() returns false and new() explains the missing dependency.
--
-- The host provides:
--   now()                  monotonic seconds via clock_gettime
--   block(rt, waits, ...)  nanosleep for time waits and epoll for readiness waits

local Host = require('fibers.host')

local function unsupported(reason)
  return {
    is_supported = function() return false, reason end,
    support_reason = function() return reason end,
    new = function() error('fibers.host.luajit_linux: ' .. tostring(reason), 2) end,
  }
end

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
  return unsupported('LuaJIT ffi not available')
end

local bit = rawget(_G, 'bit')
if not bit then
  return unsupported('LuaJIT bit operations not available')
end

local C = ffi.C
local toint = ffi.tonumber or tonumber

ffi.cdef [[
  typedef long time_t;
  struct timespec { time_t tv_sec; long tv_nsec; };

  int clock_gettime(int clk_id, struct timespec *tp);
  int nanosleep(const struct timespec *req, struct timespec *rem);

  typedef unsigned char      uint8_t;
  typedef unsigned int       uint32_t;
  typedef unsigned long long uint64_t;

  int epoll_create(int size);
  int epoll_create1(int flags);
  int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
  int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
  int close(int fd);
  char *strerror(int errnum);
]]

local jit_ = rawget(_G, 'jit')
local ARCH = ffi.arch or (jit_ and jit_.arch) or 'x64'

if ARCH == 'x64' or ARCH == 'x86' then
  ffi.cdef [[
    typedef struct epoll_event { uint8_t raw[12]; } epoll_event;
  ]]
elseif ARCH == 'mips' or ARCH == 'mipsel' or ARCH == 'arm64' or ARCH == 'aarch64' then
  ffi.cdef [[
    typedef struct epoll_event { uint32_t events; uint64_t data; } epoll_event;
  ]]
else
  return unsupported('unsupported epoll_event architecture ' .. tostring(ARCH))
end

local CLOCK_MONOTONIC = 1
local EINTR = 4
local EPERM = 1
local ENOENT = 2
local EBADF = 9
local ENOSYS = 38

local EPOLL_CLOEXEC = 0x00080000

local EPOLLIN    = 0x00000001
local EPOLLOUT   = 0x00000004
local EPOLLERR   = 0x00000008
local EPOLLHUP   = 0x00000010
local EPOLLRDHUP = 0x00002000
local EPOLLONESHOT = bit.lshift(1, 30)

local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3

local RD  = bit.bor(EPOLLIN, EPOLLRDHUP)
local WR  = EPOLLOUT
local ERR = bit.bor(EPOLLERR, EPOLLHUP)

local get_event, set_event, get_data, set_data
if ARCH == 'x64' or ARCH == 'x86' then
  get_event = function(ev) return ffi.cast('uint32_t*', ev.raw)[0] end
  set_event = function(ev, value) ffi.cast('uint32_t*', ev.raw)[0] = value end
  get_data = function(ev) return ffi.cast('uint64_t*', ev.raw + 4)[0] end
  set_data = function(ev, value) ffi.cast('uint64_t*', ev.raw + 4)[0] = value end
else
  get_event = function(ev) return ev.events end
  set_event = function(ev, value) ev.events = value end
  get_data = function(ev) return ev.data end
  set_data = function(ev, value) ev.data = value end
end

local function errno()
  return ffi.errno()
end

local function strerror(e)
  local s = C.strerror(e)
  if s == nil then return 'errno ' .. tostring(e) end
  return ffi.string(s)
end

local function read_monotonic()
  local ts = ffi.new('struct timespec[1]')
  local rc = toint(C.clock_gettime(CLOCK_MONOTONIC, ts))
  if rc ~= 0 then error('clock_gettime(CLOCK_MONOTONIC) failed: ' .. strerror(errno()), 2) end
  return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) * 1e-9
end

local function sleep_seconds(dt)
  dt = tonumber(dt) or 0
  if dt <= 0 then return true end

  local req = ffi.new('struct timespec[1]')
  local rem = ffi.new('struct timespec[1]')
  local sec = math.floor(dt)
  local nsec = math.floor((dt - sec) * 1e9 + 0.5)
  if nsec >= 1000000000 then sec = sec + 1; nsec = nsec - 1000000000 end
  req[0].tv_sec = sec
  req[0].tv_nsec = nsec

  while true do
    local rc = toint(C.nanosleep(req, rem))
    if rc == 0 then return true end
    local e = errno()
    if e == EINTR then
      req[0].tv_sec = rem[0].tv_sec
      req[0].tv_nsec = rem[0].tv_nsec
    else
      return nil, 'nanosleep failed: ' .. strerror(e)
    end
  end
end

local function wrap_error(ret)
  if ret == -1 then
    local e = errno()
    return nil, strerror(e), e
  end
  return ret, nil, nil
end

local function epoll_event_size()
  return ffi.sizeof('struct epoll_event')
end

local function validate_epoll_event_abi()
  local size = epoll_event_size()
  if (ARCH == 'x64' or ARCH == 'x86') and size ~= 12 then
    return nil, 'unexpected epoll_event ABI size for ' .. tostring(ARCH) .. ': ' .. tostring(size) .. ' (expected 12)'
  end
  if size < 12 then
    return nil, 'unexpected epoll_event ABI size for ' .. tostring(ARCH) .. ': ' .. tostring(size)
  end
  return true
end

local Linux = {}
Linux.__index = Linux

local function epoll_create()
  local first_err, first_eno
  local ok_call, ret = pcall(function() return C.epoll_create1(EPOLL_CLOEXEC) end)
  if ok_call then
    local fd, err, eno = wrap_error(ret)
    if fd then return fd end
    first_err, first_eno = err, eno
  else
    first_err = tostring(ret)
  end

  local fd, err, eno = wrap_error(C.epoll_create(1))
  if not fd then
    error(err or first_err or ('epoll_create failed: errno ' .. tostring(eno or first_eno)), 2)
  end
  return fd
end

local function epoll_ctl(epfd, op, fd, mask)
  local ev = nil
  if op ~= EPOLL_CTL_DEL then
    ev = ffi.new('struct epoll_event')
    set_event(ev, mask)
    set_data(ev, fd)
  end
  return wrap_error(C.epoll_ctl(epfd, op, fd, ev))
end

local function epoll_wait(epfd, timeout_ms, maxevents)
  maxevents = math.max(1, tonumber(maxevents) or 1)
  local events = ffi.new('struct epoll_event[?]', maxevents)
  local n = toint(C.epoll_wait(epfd, events, maxevents, timeout_ms or 0))
  if n == -1 then
    local e = errno()
    if e == EINTR then return {}, nil, e end
    return nil, strerror(e), e
  end
  local out = {}
  for i = 0, n - 1 do
    local fd = assert(toint(get_data(events[i])))
    out[fd] = assert(toint(get_event(events[i])))
  end
  return out, nil, nil
end

local function fd_of(key)
  if type(key) == 'number' then return key end
  if type(key) == 'string' and tonumber(key) then return tonumber(key) end
  if type(key) == 'table' then
    if type(key.fd) == 'number' then return key.fd end
    if type(key.fileno) == 'function' then return key:fileno() end
  end
  local n = tonumber(key)
  if n then return n end
  return nil
end

local function mask_for(modes)
  local mask = 0
  if modes.read then mask = bit.bor(mask, RD) end
  if modes.write then mask = bit.bor(mask, WR) end
  if mask ~= 0 then mask = bit.bor(mask, EPOLLONESHOT) end
  return mask
end

local function collect_readiness(waits)
  local by_fd = {}
  local unsupported = false
  local readiness = Host.readiness_waits(waits)
  for i = 1, #readiness do
    local w = readiness[i]
    local fd = fd_of(w.readiness_key)
    if not fd then
      unsupported = true
    else
      local rec = by_fd[fd]
      if not rec then rec = { fd = fd, modes = {}, waits = {} }; by_fd[fd] = rec end
      local mode = w.mode or 'read'
      if mode == 'write' or mode == 'wr' then rec.modes.write = true else rec.modes.read = true end
      rec.waits[#rec.waits + 1] = w
    end
  end
  return by_fd, unsupported
end

function Linux.new(opts)
  opts = opts or {}
  local ok_abi, abi_err = validate_epoll_event_abi()
  if not ok_abi then error('fibers.host.luajit_linux: ' .. tostring(abi_err), 2) end
  local maxevents = math.floor(tonumber(opts.maxevents) or 64)
  if maxevents < 1 then maxevents = 1 end
  local epfd = epoll_create()
  local self = setmetatable({
    kind = 'luajit_linux',
    epfd = epfd,
    maxevents = maxevents,
    active = {},
    unpollable = {},
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
  }, Linux)
  self.now = function(_rt) return read_monotonic() end
  return self
end

local function support_probe()
  local ok_abi, abi_err = validate_epoll_event_abi()
  if not ok_abi then return nil, abi_err end
  local ok_time, time_or_err = pcall(read_monotonic)
  if not ok_time then return nil, 'clock_gettime probe failed: ' .. tostring(time_or_err) end
  local ok_epoll, epfd_or_err = pcall(epoll_create)
  if not ok_epoll then return nil, 'epoll_create probe failed: ' .. tostring(epfd_or_err) end
  if epfd_or_err then pcall(function() C.close(epfd_or_err) end) end
  return true
end

function Linux.is_supported()
  local ok, reason = support_probe()
  if ok then return true end
  return false, reason
end

function Linux.support_reason()
  local ok, reason = support_probe()
  if ok then return nil end
  return reason
end

function Linux:sleep(seconds)
  return sleep_seconds(seconds)
end

function Linux:_delete(fd)
  if not self.active[fd] then self.unpollable[fd] = nil; return true end
  local ok, err, eno = epoll_ctl(self.epfd, EPOLL_CTL_DEL, fd)
  self.active[fd] = nil
  self.unpollable[fd] = nil
  if ok or eno == ENOENT or eno == EBADF then return true end
  return nil, err or ('epoll_ctl DEL failed for fd ' .. tostring(fd))
end

function Linux:_delete_withdrawn(by_fd)
  local active_to_delete = {}
  for fd in pairs(self.active) do
    if not by_fd[fd] then active_to_delete[#active_to_delete + 1] = fd end
  end
  for i = 1, #active_to_delete do
    local ok, err = self:_delete(active_to_delete[i])
    if not ok then return nil, err end
  end

  local unpollable_to_delete = {}
  for fd in pairs(self.unpollable) do
    if not by_fd[fd] then unpollable_to_delete[#unpollable_to_delete + 1] = fd end
  end
  for i = 1, #unpollable_to_delete do self.unpollable[unpollable_to_delete[i]] = nil end
  return true
end

function Linux:_register(fd, modes)
  if self.unpollable[fd] then return true, 'unpollable' end
  local mask = mask_for(modes)
  if mask == 0 then return true end

  local ok, err, eno = epoll_ctl(self.epfd, EPOLL_CTL_MOD, fd, mask)
  if ok then self.active[fd] = mask; return true end
  if eno == EPERM then self.unpollable[fd] = true; self.active[fd] = nil; return true, 'unpollable' end

  local ok2, err2, eno2 = epoll_ctl(self.epfd, EPOLL_CTL_ADD, fd, mask)
  if ok2 then self.active[fd] = mask; return true end
  if eno2 == EPERM then self.unpollable[fd] = true; self.active[fd] = nil; return true, 'unpollable' end

  return nil, err2 or err or ('epoll_ctl failed for fd ' .. tostring(fd))
end

function Linux:block(rt, waits, status, _opts)
  if not self.epfd then error('fibers.host.luajit_linux: host is closed', 2) end
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local by_fd, unsupported = collect_readiness(waits)
  local ok_del, err_del = self:_delete_withdrawn(by_fd)
  if not ok_del then error(err_del, 2) end
  local have_fd = false
  for fd, rec in pairs(by_fd) do
    have_fd = true
    local ok, err = self:_register(fd, rec.modes)
    if not ok then error(err, 2) end
  end

  if unsupported then
    if self.on_unsupported then self.on_unsupported(waits, status) end
    return nil, 'unsupported-readiness-key'
  end

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

  local synthetic = {}
  for fd, rec in pairs(by_fd) do
    if self.unpollable[fd] then synthetic[fd] = bit.band(mask_for(rec.modes), bit.bnot(EPOLLONESHOT)) end
  end

  local timeout = Host.timeout_ms(rt, deadline)
  for _ in pairs(synthetic) do timeout = 0; break end

  local evmap = synthetic
  local polled, err = epoll_wait(self.epfd, timeout, self.maxevents)
  if not polled then error(err or 'epoll_wait failed', 2) end
  for fd, mask in pairs(polled) do evmap[fd] = bit.bor(evmap[fd] or 0, mask) end

  local delivered = false
  for fd, mask in pairs(evmap) do
    local rec = by_fd[fd]
    if rec then
      local rd = bit.band(mask, bit.bor(RD, ERR)) ~= 0
      local wr = bit.band(mask, bit.bor(WR, ERR)) ~= 0
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

  if delivered then return true, 'readiness' end
  if deadline ~= nil and rt:now() >= deadline then return true, 'time' end
  -- EINTR or a timeout rounded down to zero: re-enter the runtime rather than
  -- hiding the wake from the driver.
  return true, 'poll'
end

function Linux:close()
  if self.epfd then C.close(self.epfd); self.epfd = nil end
end

return Linux
