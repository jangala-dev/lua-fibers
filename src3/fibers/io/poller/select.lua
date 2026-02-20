-- fibers/io/poller/select.lua
--
-- luaposix.poll()-based poller backend (no epoll required).
-- Compatible with Pulse-only poller core (fd sets + Pulse signalling).

local core = require 'fibers.io.poller.core'

-- Try to load luaposix poll support.
local ok, poll_mod = pcall(require, 'posix.poll')
if not ok or type(poll_mod) ~= 'table' or type(poll_mod.poll) ~= 'function' then
  return { is_supported = function () return false end }
end
local errno_mod = require 'posix.errno'

local poll_fn = poll_mod.poll

----------------------------------------------------------------------
-- Backend ops for Pulse poller core
----------------------------------------------------------------------

local function new_backend()
  -- No persistent kernel state required for poll(); everything is
  -- derived from the current fd sets on each poll call.
  return {}
end

--- Build the fds table in the shape expected by posix.poll.poll:
---   fds[fd] = { events = { IN = true, OUT = true } }
---
--- rd_set / wr_set are plain sets: set[fd] == true when watched.
local function build_fds(rd_set, wr_set)
  local fds = {}

  if rd_set then
    for fd, _ in pairs(rd_set) do
      local e = fds[fd]
      if not e then
        e = { events = {} }
        fds[fd] = e
      end
      e.events.IN = true
    end
  end

  if wr_set then
    for fd, _ in pairs(wr_set) do
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

local function poll_backend(_, timeout_ms, rd_set, wr_set)
  local fds = build_fds(rd_set, wr_set)

  -- poll() with nfds == 0 is defined and just sleeps for timeout.
  local nready, err, eno = poll_fn(fds, timeout_ms)
  if nready == nil then
    -- Treat EINTR as benign; surface other errors.
    if eno == errno_mod.EINTR then
      return {}
    end
    error(('%s (errno %s)'):format(tostring(err), tostring(eno)))
  end

  if nready == 0 then
    return {}
  end

  local events = {}

  -- luaposix reports readiness in fds[fd].revents with flags such as
  -- IN, OUT, ERR, HUP, NVAL.
  for fd, info in pairs(fds) do
    local re = info.revents
    if re then
      local rd_flag  = re.IN or re.HUP or re.ERR or re.NVAL
      local wr_flag  = re.OUT or re.ERR or re.NVAL
      local err_flag = re.ERR or re.NVAL

      if rd_flag or wr_flag or err_flag then
        events[fd] = {
          rd  = not not rd_flag,
          wr  = not not wr_flag,
          err = not not err_flag,
        }
      end
    end
  end

  return events
end

local function is_supported()
  return true
end

local ops = {
  new_backend  = new_backend,
  poll         = poll_backend,
  is_supported = is_supported,
}

local function new()
  return core.new(ops)
end

return {
  new          = new,
  is_supported = is_supported,
}
