-- fibers/io/poller/epoll.lua
--
-- Linux epoll-based poller backend.
-- Supports LuaJIT (ffi) and PUC Lua with cffi.
-- Intended to be selected via fibers.io.poller.

local runtime = require 'fibers.runtime'
local wait    = require 'fibers.wait'
local safe    = require 'coxpcall'

local bit     = rawget(_G, "bit") or require 'bit32'
local ffi_c   = require 'fibers.utils.ffi_compat'

----------------------------------------------------------------------
-- FFI / CFFI setup via ffi_compat
----------------------------------------------------------------------

if not (ffi_c.is_supported and ffi_c.is_supported()) then
  return { is_supported = function() return false end }
end

local ffi         = ffi_c.ffi
local C           = ffi_c.C
local ffi_tonumber = ffi_c.tonumber
local get_errno   = ffi_c.errno

local EINTR  = 4
local ENOENT = 2
local EBADF  = 9

local ARCH = ffi.arch or ((jit and jit.arch) or "x64")

----------------------------------------------------------------------
-- Low-level epoll bindings (local to this file)
----------------------------------------------------------------------

ffi.cdef[[
  typedef unsigned char      uint8_t;
  typedef unsigned int       uint32_t;
  typedef unsigned long long uint64_t;

  int epoll_create(int size);
  int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
  int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);

  int close(int fd);
  char *strerror(int errnum);
]]

-- epoll_event layout differs by architecture.
if ARCH == "x64" or ARCH == "x86" then
  ffi.cdef[[
    typedef struct epoll_event {
      uint8_t raw[12];  // 4 bytes for events + 8 bytes for data
    } epoll_event;
  ]]
elseif ARCH == "mips" or ARCH == "mipsel" or ARCH == "arm64" then
  ffi.cdef[[
    typedef struct epoll_event {
      uint32_t events;
      uint64_t data;
    } epoll_event;
  ]]
else
  error("fibers.io.poller.epoll: unsupported architecture " .. tostring(ARCH))
end

-- Event bits.
local EPOLLIN      = 0x00000001
local EPOLLOUT     = 0x00000004
local EPOLLERR     = 0x00000008
local EPOLLHUP     = 0x00000010
local EPOLLRDHUP   = 0x00002000
local EPOLLONESHOT = bit.lshift(1, 30)

local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3

-- Architecture-dependent field access.
local get_event, set_event, get_data, set_data

if ARCH == "x64" or ARCH == "x86" then
  get_event = function(ev)
    return ffi.cast("uint32_t*", ev.raw)[0]
  end
  set_event = function(ev, value)
    ffi.cast("uint32_t*", ev.raw)[0] = value
  end
  get_data = function(ev)
    return ffi.cast("uint64_t*", ev.raw + 4)[0]
  end
  set_data = function(ev, value)
    ffi.cast("uint64_t*", ev.raw + 4)[0] = value
  end
else
  get_event = function(ev)
    return ev.events
  end
  set_event = function(ev, value)
    ev.events = value
  end
  get_data = function(ev)
    return ev.data
  end
  set_data = function(ev, value)
    ev.data = value
  end
end

local function wrap_error(ret)
  if ret == -1 then
    local errno = get_errno()
    local err   = ffi.string(C.strerror(errno))
    return nil, err, errno
  end
  return ret, nil, nil
end

local function epoll_create()
  local fd, err, errno = wrap_error(C.epoll_create(1))
  if not fd then
    error(err or ("epoll_create failed (errno " .. tostring(errno) .. ")"))
  end
  return fd
end

local function epoll_ctl_add(epfd, fd, mask)
  local ev = ffi.new("struct epoll_event")
  set_event(ev, mask)
  set_data(ev, fd)
  return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev))
end

local function epoll_ctl_mod(epfd, fd, mask)
  local ev = ffi.new("struct epoll_event")
  set_event(ev, mask)
  set_data(ev, fd)
  return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev))
end

local function epoll_ctl_del(epfd, fd)
  return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_DEL, fd, nil))
end

local function epoll_wait(epfd, timeout_ms, max_events)
  local events = ffi.new("struct epoll_event[?]", max_events)
  local n      = C.epoll_wait(epfd, events, max_events, timeout_ms)
  if n == -1 then
    local errno = get_errno()
    if errno == EINTR then
      -- Benign interruption: report “no events”.
      return {}, nil, errno
    end
    local err = ffi.string(C.strerror(errno))
    return nil, err, errno
  end

  local res = {}
  for i = 0, n - 1 do
    local fd    = assert(ffi_tonumber(get_data(events[i])))
    local event = assert(ffi_tonumber(get_event(events[i])))
    res[fd] = event
  end

  return res, nil, nil
end

local function epoll_close(epfd)
  return wrap_error(C.close(epfd))
end

----------------------------------------------------------------------
-- Epoll wrapper object
----------------------------------------------------------------------

---@class Epoll
---@field epfd integer
---@field active_events table<integer, integer>
---@field maxevents integer
local Epoll = {}
Epoll.__index = Epoll

local INITIAL_MAXEVENTS = 8

local function new_epoll()
  local ret = {
    epfd          = epoll_create(),
    active_events = {},
    maxevents     = INITIAL_MAXEVENTS,
  }
  return setmetatable(ret, Epoll)
end

local RD  = EPOLLIN + EPOLLRDHUP
local WR  = EPOLLOUT
local ERR = EPOLLERR + EPOLLHUP

function Epoll:add(fd, events)
  local active    = self.active_events[fd] or 0
  local eventmask = bit.bor(events, active, EPOLLONESHOT)
  local ok        = epoll_ctl_mod(self.epfd, fd, eventmask)
  if not ok then
    assert(epoll_ctl_add(self.epfd, fd, eventmask))
  end
  self.active_events[fd] = eventmask
end

function Epoll:poll(timeout_ms)
  local events, err, errno = epoll_wait(self.epfd, timeout_ms or 0, self.maxevents)
  if not events then
    error(err or "epoll_wait failed (errno " .. tostring(errno) .. ")")
  end

  local count = 0
  for fd, _ in pairs(events) do
    count = count + 1
    self.active_events[fd] = nil
  end

  if count == self.maxevents then
    self.maxevents = self.maxevents * 2
  end

  return events, nil
end

function Epoll:del(fd)
  local ok, err, errno = epoll_ctl_del(self.epfd, fd)
  if not ok then
    -- ENOENT/EBADF: fd already closed or never registered; just clear.
    if errno == ENOENT or errno == EBADF then
      self.active_events[fd] = nil
      return
    end
    error(err or "epoll_ctl(DEL) failed (errno " .. tostring(errno) .. ")")
  end
  self.active_events[fd] = nil
end

function Epoll:close()
  epoll_close(self.epfd)
  self.epfd = nil
end

----------------------------------------------------------------------
-- Poller TaskSource built on Epoll
----------------------------------------------------------------------

---@class Poller : TaskSource
---@field ep Epoll
---@field rd Waitset
---@field wr Waitset
local Poller = {}
Poller.__index = Poller

local function new_poller()
  return setmetatable({
    ep = new_epoll(),
    rd = wait.new_waitset(),
    wr = wait.new_waitset(),
  }, Poller)
end

local function recompute_mask(self, fd)
  local need_rd = not self.rd:is_empty(fd)
  local need_wr = not self.wr:is_empty(fd)
  local mask = 0
  if need_rd then mask = bit.bor(mask, RD) end
  if need_wr then mask = bit.bor(mask, WR) end

  if mask ~= 0 then
    self.ep:add(fd, mask)
  else
    self.ep:del(fd)
  end
end

--- Register a task as waiting on an fd for read or write readiness.
---@param fd integer
---@param dir '"rd"'|'"wr"'
---@param task Task
---@return WaitToken
function Poller:wait(fd, dir, task)
  assert(type(fd) == 'number', "fd must be number")
  assert(dir == "rd" or dir == "wr", "dir must be 'rd' or 'wr'")

  local ws    = (dir == "rd") and self.rd or self.wr
  local token = ws:add(fd, task)

  recompute_mask(self, fd)

  local original_unlink = token.unlink
  local owner           = self

  function token.unlink(tok)
    local emptied = original_unlink(tok)
    if emptied then
      recompute_mask(owner, fd)
    end
    return emptied
  end

  return token
end

--- TaskSource hook: poll epoll and schedule ready tasks.
---@param sched Scheduler
---@param _ number|nil
---@param timeout number|nil  -- seconds
function Poller:schedule_tasks(sched, _, timeout)
  if timeout == nil then timeout = 0 end
  if timeout >= 0 then timeout = timeout * 1e3 end

  local events = self.ep:poll(timeout)
  for fd, ev in pairs(events) do
    if bit.band(ev, RD + ERR) ~= 0 then
      self.rd:notify_all(fd, sched)
    end
    if bit.band(ev, WR + ERR) ~= 0 then
      self.wr:notify_all(fd, sched)
    end
    recompute_mask(self, fd)
  end
end

Poller.wait_for_events = Poller.schedule_tasks

function Poller:close()
  self.ep:close()
  self.ep = nil
end

----------------------------------------------------------------------
-- Singleton and capability probe
----------------------------------------------------------------------

local singleton

local function get()
  if singleton then return singleton end
  singleton = new_poller()
  local sched = runtime.current_scheduler
  assert(sched.add_task_source, "scheduler must implement add_task_source")
  sched:add_task_source(singleton)
  return singleton
end

local function is_supported()
  local ok = safe.pcall(function()
    local e = new_epoll()
    e:close()
  end)
  return ok
end

return {
  get          = get,
  Poller       = Poller,
  is_supported = is_supported,
}
