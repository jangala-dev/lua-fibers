---
-- Epoll-based poller integration for fibers.
--
-- Provides a singleton Poller that:
--   * integrates an epoll backend with the scheduler,
--   * exposes a wait(fd, dir, task) API used by IO backends,
--   * acts both as a TaskSource and as the scheduler's event_waiter.
--
-- schedule_tasks is used in two modes:
--   * as a normal source: non-blocking poll (timeout coerced to 0),
--   * as event_waiter: blocking poll with the scheduler's timeout.
---@module 'fibers.io.poller'

local runtime = require 'fibers.runtime'
local epoll   = require 'fibers.io.epoll'
local bit     = rawget(_G, "bit") or require 'bit32'
local wait    = require 'fibers.wait'

--- Epoll-based poller registered as a scheduler TaskSource.
---@class Poller : TaskSource
---@field ep any     # epoll backend handle
---@field rd Waitset # fd -> tasks waiting for read
---@field wr Waitset # fd -> tasks waiting for write
local Poller = {}
Poller.__index = Poller

--- Create a new poller instance.
---@return Poller
local function new_poller()
  return setmetatable({
    ep = epoll.new(),
    rd = wait.new_waitset(), -- fd -> tasks waiting for read
    wr = wait.new_waitset(), -- fd -> tasks waiting for write
  }, Poller)
end

--- Recompute epoll interest mask for a single fd from rd/wr waitsets.
---@param self Poller
---@param fd integer
local function recompute_mask(self, fd)
  local need_rd = not self.rd:is_empty(fd)
  local need_wr = not self.wr:is_empty(fd)
  local mask = 0
  if need_rd then mask = bit.bor(mask, epoll.RD) end
  if need_wr then mask = bit.bor(mask, epoll.WR) end
  if mask ~= 0 then
    -- ep:add is expected to behave as add-or-modify for existing fds.
    self.ep:add(fd, mask)
  else
    self.ep:del(fd)
  end
end

--- Register a task as waiting on an fd for read or write readiness.
---
--- The returned token's unlink() will deregister the task from the
--- relevant Waitset and keep the epoll mask in sync.
---@param fd integer
---@param dir '"rd"'|'"wr"'
---@param task Task
---@return WaitToken
function Poller:wait(fd, dir, task)
  assert(type(fd) == 'number', "fd must be number")
  assert(dir == "rd" or dir == "wr", "dir must be 'rd' or 'wr'")

  local ws = (dir == "rd") and self.rd or self.wr
  local token = ws:add(fd, task)

  -- Ensure epoll is armed now there is at least one waiter.
  recompute_mask(self, fd)

  -- Wrap unlink so we keep epoll mask in sync when buckets empty.
  local original_unlink = token.unlink
  local owner = self

  ---@param tok WaitToken
  ---@return boolean
  function token.unlink(tok)
    local emptied = original_unlink(tok)
    if emptied then
      recompute_mask(owner, fd)
    end
    return emptied
  end

  return token
end

--- TaskSource hook: poll epoll and schedule any ready tasks.
---
--- Called in two contexts:
---   * from Scheduler:schedule_tasks_from_sources(now) with timeout=nil
---     (effectively non-blocking),
---   * from Scheduler:wait_for_events(now, timeout) as event_waiter.
---@param sched Scheduler
---@param _ number|nil  -- current monotonic time (unused here)
---@param timeout number|nil  -- seconds
function Poller:schedule_tasks(sched, _, timeout)
  -- timeout in seconds; epoll_wait in milliseconds.
  if timeout == nil then timeout = 0 end
  if timeout >= 0 then timeout = timeout * 1e3 end

  for fd, ev in pairs(self.ep:poll(timeout)) do
    if bit.band(ev, epoll.RD + epoll.ERR) ~= 0 then
      self.rd:notify_all(fd, sched)
    end
    if bit.band(ev, epoll.WR + epoll.ERR) ~= 0 then
      self.wr:notify_all(fd, sched)
    end
    recompute_mask(self, fd)
  end
end

--- Event waiter hook; aliased to schedule_tasks.
--- The scheduler treats this as a blocking wait with a timeout.
Poller.wait_for_events = Poller.schedule_tasks

--- Close the underlying epoll handle.
function Poller:close()
  self.ep:close()
  self.ep = nil
end

-- Singleton wiring.
local singleton

--- Get the process-wide poller instance, creating and registering it if needed.
---@return Poller
local function get()
  if singleton then return singleton end
  singleton = new_poller()
  local sched = runtime.current_scheduler
  if sched.add_task_source then
    sched:add_task_source(singleton)
  else
    -- Fallback for older schedulers without add_task_source.
    sched.sources = sched.sources or {}
    table.insert(sched.sources, singleton)
  end
  return singleton
end

return {
  get = get
}
