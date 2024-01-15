--- Tests the Epoll implementation.
print('testing: fibers.epoll')

-- look one level up
package.path = "../?.lua;" .. package.path

local epoll = require 'fibers.epoll'
local sc = require 'fibers.utils.syscall'
local bit = rawget(_G, "bit") or require 'bit32'

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

-- Basic polling test
assert(equal(poll(), {}))

-- Test using pipes, a common FD type
local rd, wr = sc.pipe()

-- Test adding and polling multiple times
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

-- Data-specific testing: Here we are ensuring the correct functioning of our epoll data structure.
-- Simulate a change in epoll_event's internal data
local eventmask = bit.bor(RD, WR, sc.EPOLLONESHOT)
myepoll:add(rd, eventmask)
local events = poll(10)
for _, evt in ipairs(events) do
    if evt.fd == rd then
        assert(bit.band(evt.events, RD) ~= 0, "Expected read event not found.")
        assert(bit.band(evt.events, WR) ~= 0, "Expected write event not found.")
    end
end

-- Testing Error Scenarios:
-- Try adding a closed FD
sc.close(rd)
local errorThrown = false
local result, errmsg = pcall(function()
    myepoll:add(rd, RD)
end)

if not result then
    errorThrown = true
end

assert(errorThrown, "Expected an error when adding a closed FD.")

-- Boundary Testing
-- Adding more FDs than the epoll's current max_events limit.
local fds = {}
for i=1, myepoll.maxevents*2 do
    local r, w = sc.pipe()
    table.insert(fds, {r, w})
    pcall(function() myepoll:add(r, RD) end)
    pcall(function() myepoll:add(w, WR) end)
end
for _, fdpair in ipairs(fds) do
    sc.close(fdpair[1])
    sc.close(fdpair[2])
end

print('test: ok')
