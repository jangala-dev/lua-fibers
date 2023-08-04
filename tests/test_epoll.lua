--- Tests the Epoll implementation.
print('testing: fibers.epoll')

-- look one level up
package.path = "../?.lua;" .. package.path

local epoll = require 'fibers.epoll'
local sc = require 'fibers.utils.syscall'

local equal = require 'fibers.utils.helper'.equal

local myepoll = assert(epoll.new())
local function poll(timeout)
   local events = {}
   local retvalue, _ = myepoll:poll(timeout)
   for fd, event in pairs(retvalue) do
      table.insert(events, {fd=fd, events=event})
   end
   return events
end
assert(equal(poll(), {}))
local rd, wr = sc.pipe()
for i = 1,10 do
   myepoll:add(rd, RD)
   myepoll:add(wr, WR)
   assert(equal(poll(), {{fd=wr, events=WR}}))
   assert(sc.write(wr, "foo") == 3)
   -- The write end isn't active because we haven't re-added it to the
   -- epoll set.
   assert(equal(poll(), {{fd=rd, events=sc.EPOLLIN}}))
   -- Now nothing is active, so no events even though both sides can
   -- do I/O.
   assert(equal(poll(), {}))
   myepoll:add(rd, RD)
   myepoll:add(wr, WR)
   -- Having re-added them though they are indeed active.
   assert(#poll() == 2)
   assert(sc.read(rd, 50) == "foo")
end

print('test: ok')
