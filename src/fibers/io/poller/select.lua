-- fibers/io/poller/select.lua
--
-- posix.poll()-based poller backend (no epoll required).
-- Intended to be selected via fibers.io.poller.

---@module 'fibers.io.poller.select'

local runtime = require 'fibers.runtime'
local wait    = require 'fibers.wait'

-- Try to load luaposix poll support.
local ok, poll_mod = pcall(require, 'posix.poll')
if not ok or type(poll_mod) ~= "table" or type(poll_mod.poll) ~= "function" then
  -- Backend is present but unusable on this platform.
  return {
    is_supported = function() return false end,
  }
end

local poll_fn = poll_mod.poll

---@class Waitset
---@field buckets table<any, Task[]>

---@class SelectPoller : TaskSource
---@field rd Waitset   # fd -> tasks waiting for read
---@field wr Waitset   # fd -> tasks waiting for write
local SelectPoller = {}
SelectPoller.__index = SelectPoller

local function new_poller()
  return setmetatable({
    rd = wait.new_waitset(),
    wr = wait.new_waitset(),
  }, SelectPoller)
end

--- Register a task as waiting on an fd for read or write readiness.
---@param fd integer
---@param dir '"rd"'|'"wr"'
---@param task Task
---@return WaitToken
function SelectPoller:wait(fd, dir, task)
  assert(type(fd) == 'number', "fd must be number")
  assert(dir == "rd" or dir == "wr", "dir must be 'rd' or 'wr'")

  local ws = (dir == "rd") and self.rd or self.wr
  return ws:add(fd, task)
end

--- Build the fds table in the shape expected by posix.poll.poll:
---   fds[fd] = { events = { IN = true, OUT = true } }
---@param self SelectPoller
---@return table
local function build_fds(self)
  local fds = {}

  -- Any fd with one or more read waiters gets IN.
  for fd, list in pairs(self.rd.buckets) do
    if list and #list > 0 then
      local e = fds[fd]
      if not e then
        e = { events = {} }
        fds[fd] = e
      end
      e.events.IN = true
    end
  end

  -- Any fd with one or more write waiters gets OUT.
  for fd, list in pairs(self.wr.buckets) do
    if list and #list > 0 then
      local e = fds[fd]
      if not e then
        e = { events = {} }
        fds[fd] = e
      end
      e.events.OUT = true
    end
  end

  return fds
end

--- TaskSource hook: poll and schedule any ready tasks.
---@param sched Scheduler
---@param _ number|nil        -- current monotonic time (unused)
---@param timeout number|nil  -- seconds
function SelectPoller:schedule_tasks(sched, _, timeout)
  -- Convert timeout from seconds to milliseconds for posix.poll.
  local timeout_ms
  if timeout == nil then
    timeout_ms = 0
  elseif timeout < 0 then
    timeout_ms = -1
  else
    timeout_ms = math.floor(timeout * 1e3 + 0.5)
  end

  local fds = build_fds(self)

  -- poll() with nfds == 0 is defined and just sleeps for timeout.
  local nready, err, errno = poll_fn(fds, timeout_ms)
  if nready == nil then
    -- Treat as a hard failure: surfaced as a normal Lua error, which
    -- will be caught by the scope/fibre machinery.
    error(("%s (errno %s)"):format(tostring(err), tostring(errno)))
  end

  if nready == 0 then
    return
  end

  -- Wake tasks for any fd that reported events.
  --
  -- luaposix reports readiness in fds[fd].revents with flags
  -- such as IN, OUT, ERR, HUP, NVAL.
  for fd, info in pairs(fds) do
    local re = info.revents
    if re then
      if re.IN or re.HUP or re.ERR or re.NVAL then
        self.rd:notify_all(fd, sched)
      end
      if re.OUT or re.ERR or re.NVAL then
        self.wr:notify_all(fd, sched)
      end
    end
  end
end

-- Used as the scheduler's event_waiter.
SelectPoller.wait_for_events = SelectPoller.schedule_tasks

function SelectPoller:close()
  self.rd:clear_all()
  self.wr:clear_all()
end

-- Singleton wiring (mirrors the epoll poller pattern).
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
  return true
end

return {
  get          = get,
  Poller       = SelectPoller,
  is_supported = is_supported,
}
