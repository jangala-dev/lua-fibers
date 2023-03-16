-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Hierarchical timer wheel inspired by Juho Snellman's "Ratas".  For a
-- detailed discussion, see:
--
--   https://www.snellman.net/blog/archive/2016-07-27-ratas-hierarchical-timer-wheel/

-- Require path modification
package.path = '../?.lua;' .. package.path

-- Required packages
local sc = require('fibers.utils.syscall')

-- Constants
local WHEEL_SLOTS = 256
local WHEEL_SLOT_PERIOD = 1e-3

--- TimerWheel prototype
local TimerWheel = {}
TimerWheel.__index = TimerWheel

local function push_node(node, head)
    node.prev, node.next, head.prev.next, head.prev = head.prev, head, node, node
end

local function pop_node(head)
    local node = head.next
    head.next, node.next.prev = node.next, head
    return node
end

local function allocate_timer_entry()
    return { time=false, prev=false, next=false, obj=false }
end

local timer_entry_freelist = {}

local function new_timer_entry()
    local pos = #timer_entry_freelist
    if pos ~= 0 then
        local ent = timer_entry_freelist[pos]
        timer_entry_freelist[pos] = nil
        return ent
    end
    return allocate_timer_entry()
end

--- Creates a new timer entry.
local function make_timer_entry(t, obj)
    local ent = new_timer_entry()
    ent.time, ent.obj = t, obj
    return ent
end

--- Recycles timer entries to reduce garbage collection.
local function recycle_timer_entry(ent)
    ent.time, ent.next, ent.prev, ent.obj = false, false, false, false
    timer_entry_freelist[#timer_entry_freelist+1] = ent
end

--- Creates empty timer slots to populate a new timer wheel.
local function new_slots()
    local ret = {}
    for slot=0,WHEEL_SLOTS-1 do
        local head = make_timer_entry(false, false)
        head.prev, head.next = head, head
        ret[slot] = head
    end
    return ret
end

--- Creates a new timer wheel.
local function new_timer_wheel(now, period)
    now, period = now or sc.monotime(), period or WHEEL_SLOT_PERIOD
    return setmetatable(
        { now=now, period=period, rate=1/period, cur=0,
          slots=new_slots(), outer=false }, TimerWheel)
end

--- Adds a new outer wheel.
local function add_wheel(inner)
    local base = inner.now + inner.period * (WHEEL_SLOTS - inner.cur)
    inner.outer = new_timer_wheel(base, inner.period * WHEEL_SLOTS)
end

--- Adds an object to the timer wheel at a relative time.
function TimerWheel:add_delta(dt, obj)
    return self:add_absolute(self.now + dt, obj)
end

--- Adds an object to the timer wheel at an absolute time.
function TimerWheel:add_absolute(t, obj)
    local offset = math.max(math.floor((t - self.now) * self.rate), 0) -- the number of ticks ahead to add the event 
    if offset < WHEEL_SLOTS then -- can the number of ticks be accommodated within the wheel?
        local idx = (self.cur + offset) % WHEEL_SLOTS -- this modulus allows timer entries to a slot in the wheel before the current time, so will be activated in the next tick prevent having to be redistributed from the outer wheel. Smart!
        local ent = make_timer_entry(t, obj)
        push_node(ent, self.slots[idx])
        return ent
    else
        if not self.outer then add_wheel(self) end -- if no outer wheel then add one
        return self.outer:add_absolute(t, obj) -- recurses outwards 
    end
end

--- Finds the next event in a slot. 
local function slot_min_time(head)
    local min = 1/0
    local ent = head.next
    while ent ~= head do
        min = math.min(ent.time, min)
        ent = ent.next
    end
    return min
end

--- Finds the next event in the wheel. 
function TimerWheel:next_entry_time()
    for offset=0,WHEEL_SLOTS-1 do
        local idx = (self.cur + offset) % WHEEL_SLOTS
        local head = self.slots[idx]
        if head ~= head.next then
            local t = slot_min_time(head)
            if self.outer then
                -- Unless we just migrated entries from outer to inner wheel
                -- on the last tick, outer wheel overlaps with inner.
                local outer_idx = (self.outer.cur + offset) % WHEEL_SLOTS
                t = math.min(t, slot_min_time(self.outer.slots[outer_idx]))
            end
            return t
        end
    end
    if self.outer then return self.outer:next_entry_time() end
    return 1/0 -- lua has a notion of infinity, who knew?
end

--- Advances the outer wheel a tick, assigning all entries to current wheel.
local function tick_outer(inner, outer)
    if not outer then return end
    local head = outer.slots[outer.cur]
    while head.next ~= head do
        local ent = pop_node(head)
        local idx = math.floor((ent.time - outer.now) * inner.rate)
        -- Because of floating-point imprecision it's possible to get an
        -- index that falls just outside [0,WHEEL_SLOTS-1].
        idx = math.max(math.min(idx, WHEEL_SLOTS-1), 0)
        push_node(ent, inner.slots[idx])
    end
    outer.cur = (outer.cur + 1) % WHEEL_SLOTS
    -- Adjust inner clock; outer period is more precise than N additions
    -- of the inner period.
    inner.now, outer.now = outer.now, outer.now + outer.period
    if outer.cur == 0 then tick_outer(outer, outer.outer) end
end

--- Advances the current wheel a tick.
local function tick(wheel, sched)
    local head = wheel.slots[wheel.cur]
    while head.next ~= head do
        local ent = pop_node(head)
        local obj = ent.obj
        recycle_timer_entry(ent)
        sched:schedule(obj)
    end
    wheel.cur = (wheel.cur + 1) % WHEEL_SLOTS
    wheel.now = wheel.now + wheel.period
    if wheel.cur == 0 then tick_outer(wheel, wheel.outer) end
end

--- Advances the timer wheel by a fixed time in seconds t.
function TimerWheel:advance(t, sched)
    while t >= self.now + self.period do tick(self, sched) end
end

local function selftest ()
    print("selftest: lib.fibers.timer")
    local wheel = new_timer_wheel(10, 1e-3)

    -- At millisecond precision, advancing the wheel by an hour shouldn't
    -- take perceptible time.
    local hour = 60*60
    wheel:advance(hour)

    local event_count = 1e4
    local t = wheel.now
    for _=1,event_count do
        local dt = math.random()
        t = t + dt
        wheel:add_absolute(t, t) -- this is adding a simple number as the payload stored in the timer wheel
    end

    local last = 0
    local count = 0
    local check = {}
    function check:schedule(t) -- in the call to wheel:advance below, this method is called and provided the payload inserted into the wheel, if it were really a scheduler it would resume the coroutine stored in the wheel??
        local now = wheel.now
        -- The timer wheel only guarantees ordering between ticks, not
        -- ordering within a tick.  It doesn't even guarantee insertion
        -- order within a tick.  However for this test we know that
        -- insertion order is preserved.
        assert(last <= t)
        last, count = t, count + 1
        -- Check that timers fire within a tenth a tick of when they
        -- should.  Floating-point imprecisions can cause either slightly
        -- early or slightly late ticks.
        assert(now - wheel.period*0.1 < t)
        assert(t < now + wheel.period*1.1)
    end

    wheel:advance(t+1, check) -- this advances the wheel by t, which is the cumulative time of all the events added above

    assert(count == event_count)

    print("selftest: ok")
end

return {
    new_timer_wheel = new_timer_wheel,
    selftest = selftest
}