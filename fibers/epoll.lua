-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Fibers.

package.path = "../?.lua;" .. package.path

local bit = require('bit32')
local epoll = require('epoll')

local Epoll = {}

local INITIAL_MAXEVENTS = 8

local function new()
   local ret = { epfd = assert(epoll.create()),
                 active_events = {},
                 maxevents = INITIAL_MAXEVENTS,
               }
   return setmetatable(ret, { __index = Epoll })
end

RD = epoll.EPOLLIN + epoll.EPOLLRDHUP
WR = epoll.EPOLLOUT
RDWR = RD + WR
ERR = epoll.EPOLLERR + epoll.EPOLLHUP

function Epoll:add(s, events)
   local fd = s
   local active = self.active_events[fd] or 0
   local eventmask = bit.bor(events, active, epoll.EPOLLONESHOT)
   local ok, err = epoll.modify(self.epfd, fd, eventmask)
   if not ok then assert(epoll.register(self.epfd, fd, eventmask)) end
end

function Epoll:poll(timeout)
   -- Returns a table, an iterator would be more efficient.
   -- print("self.epfd", self.epfd)
   -- print("self.maxevents", self.maxevents)
   local events, err = epoll.wait(self.epfd, timeout or 0, self.maxevents)
   if not events then
      error(err)
   end
   local count = 0
   -- Since we add fd's with EPOLL_ONESHOT, now that the event has
   -- fired, the fd is now deactivated.  Record that fact.
   for fd, event in pairs(events) do
      count = count + 1
      self.active_events[fd] = nil
   end
   if count == self.maxevents then
      -- If we received `maxevents' events, it means that probably there
      -- are more active fd's in the queue that we were unable to
      -- receive.  Expand our event buffer in that case.
      self.maxevents = self.maxevents * 2
   end
   return events, err
end

function Epoll:close()
   self.epfd:close()
   self.epfd = nil
end

local function selftest()
   print('selftest: lib.fibers.epoll')
   local S = require 'posix.unistd'
   local equal = require 'fibers.utils.helper'.equal
   local myepoll = new()
   print("myepoll", myepoll)
   local function poll(timeout)
      local events = {}
      local retvalue, err = myepoll:poll(timeout)
      print("retvalue", retvalue, "err", err)
      for fd, event in pairs(retvalue) do
         print("fd", fd, "event", event)
         table.insert(events, {fd=fd, events=event})
      end
      return events
   end
   assert(equal(poll(), {}))
   local rd, wr = S.pipe()
   for i = 1,10 do
      myepoll:add(rd, RD)
      myepoll:add(wr, WR)
      assert(equal(poll(), {{fd=wr, events=WR}}))
      assert(S.write(wr, "foo") == 3)
      -- The write end isn't active because we haven't re-added it to the
      -- epoll set.
      assert(equal(poll(), {{fd=rd, events=epoll.EPOLLIN}}))
      -- Now nothing is active, so no events even though both sides can
      -- do I/O.
      assert(equal(poll(), {}))
      myepoll:add(rd, RD)
      myepoll:add(wr, WR)
      -- Having re-added them though they are indeed active.
      assert(#poll() == 2)
      assert(S.read(rd, 50) == "foo")
   end
   print('selftest: ok')
end

return {
   new = new,
   selftest = selftest
}