-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Fibers.

package.path = "../?.lua;" .. package.path

local bit = require('bit32')
local libepoll = require('epoll')

local Epoller = {}

local INITIAL_MAXEVENTS = 8

local function new()
   local ret = { epfd = assert(libepoll.create()),
                 active_events = {},
                 maxevents = INITIAL_MAXEVENTS,
               }
   return setmetatable(ret, { __index = Epoller })
end

RD = libepoll.EPOLLIN + libepoll.EPOLLRDHUP
WR = libepoll.EPOLLOUT
RDWR = RD + WR
ERR = libepoll.EPOLLERR + libepoll.EPOLLHUP

function Epoller:add(s, events)
   -- local fd = type(s) == 'number' and s or sc.fileno(s)
   local fd = s
   local active = self.active_events[fd] or 0
   local eventmask = bit.bor(events, active, libepoll.EPOLLONESHOT)
   local ok, err = libepoll.modify(self.epfd, fd, eventmask)
   if not ok then assert(libepoll.register(self.epfd, fd, eventmask)) end
end

function Epoller:poll(timeout)
   -- Returns a table, an iterator would be more efficient.
   -- print("self.epfd", self.epfd)
   -- print("self.maxevents", self.maxevents)
   local events, err = libepoll.wait(self.epfd, timeout or 0, self.maxevents)
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

function Epoller:close()
   self.epfd:close()
   self.epfd = nil
end

local function selftest()
   print('selftest: lib.fibers.epoll')
   local S = require 'posix.unistd'
   local equal = require 'fibers.utils.helper'.equal
   local myepoll = assert(new())
   local function poll(timeout)
      local events = {}
      local retvalue, err = myepoll:poll(timeout)
      for fd, event in pairs(retvalue) do
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
      assert(equal(poll(), {{fd=rd, events=libepoll.EPOLLIN}}))
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
   selftest = selftest,
   RD = RD,
   WR = WR,
   RDWR = RDWR,
   ERR = ERR,
}