-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Epoll.
---@module 'fibers.io.epoll'

local sc  = require 'fibers.utils.syscall'
local bit = rawget(_G, "bit") or require 'bit32'

--- Epoll handle and state.
---@class Epoll
---@field epfd integer                 # epoll file descriptor
---@field active_events table<integer, integer>  # fd -> current event mask
---@field maxevents integer            # current maximum events per epoll_wait
local Epoll = {}

---@type integer
local INITIAL_MAXEVENTS = 8

--- Create a new Epoll instance.
---@return Epoll
local function new()
    local ret = {
        epfd          = assert(sc.epoll_create()),
        active_events = {},             -- fd -> mask
        maxevents     = INITIAL_MAXEVENTS,
    }
    return setmetatable(ret, { __index = Epoll })
end

---@type integer
local RD   = sc.EPOLLIN + sc.EPOLLRDHUP
---@type integer
local WR   = sc.EPOLLOUT
---@type integer
local RDWR = RD + WR
---@type integer
local ERR  = sc.EPOLLERR + sc.EPOLLHUP

--- Add or modify interest for a file descriptor.
---
--- The descriptor is registered with EPOLLONESHOT; after an event
--- fires it becomes inactive until re-armed via this method.
---@param s integer  # file descriptor
---@param events integer  # epoll event mask
function Epoll:add(s, events)
    -- local fd = type(s) == 'number' and s or sc.fileno(s)
    local fd = s
    local active    = self.active_events[fd] or 0
    local eventmask = bit.bor(events, active, sc.EPOLLONESHOT)
    local ok, _     = sc.epoll_modify(self.epfd, fd, eventmask)
    if not ok then
        assert(sc.epoll_register(self.epfd, fd, eventmask))
    end
    self.active_events[fd] = eventmask
end

--- Wait for events.
---
--- Returns a map of fd -> event mask. EINTR is treated as benign and
--- yields an empty table.
---@param timeout? integer  # timeout in milliseconds (default 0)
---@return table<integer, integer> events, string|nil err
function Epoll:poll(timeout)
    -- Returns a table, an iterator would be more efficient.
    local events, err, errno = sc.epoll_wait(self.epfd, timeout or 0, self.maxevents)
    if not events then
        -- Treat EINTR as a benign interruption and report no events.
        if errno == sc.EINTR then
            return {}, nil
        end
        -- Other errors are considered fatal at this level.
        error(err)
    end
    local count = 0
    -- Since we add fd's with EPOLL_ONESHOT, now that the event has
    -- fired, the fd is now deactivated. Record that fact.
    for fd, _ in pairs(events) do
        count = count + 1
        self.active_events[fd] = nil
    end
    if count == self.maxevents then
        -- If we received `maxevents' events, it means that probably there
        -- are more active fd's in the queue that we were unable to
        -- receive. Expand our event buffer in that case.
        self.maxevents = self.maxevents * 2
    end
    return events, err
end

--- Remove interest in a file descriptor.
---
--- ENOENT/EBADF are treated as benign and only clear bookkeeping.
---@param fd integer
function Epoll:del(fd)
    local ok, err, errno = sc.epoll_unregister(self.epfd, fd)
    if not ok then
        -- It is possible to see ENOENT/EBADF here if the fd was
        -- already closed or never registered. Treat those as benign
        -- and just clear our bookkeeping.
        if errno == sc.ENOENT or errno == sc.EBADF then
            self.active_events[fd] = nil
            return
        end
        error(err)
    end
    self.active_events[fd] = nil
end

--- Close the epoll instance.
function Epoll:close()
    sc.epoll_close(self.epfd)
    self.epfd = nil
end

return {
    new  = new,

    RD   = RD,
    WR   = WR,
    RDWR = RDWR,
    ERR  = ERR,
}
