-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- TimerWheel module inspired by Juho Snellman's "Ratas".
-- Implements a hierarchical timing wheel. This is a time based event scheduler, used for efficiently scheduling and managing events.
-- @module fibers.timer

-- Require path modification
package.path = '../?.lua;' .. package.path

-- Required packages
local sc = require 'fibers.utils.syscall'

-- Constants
local WHEEL_SLOTS = 256
local WHEEL_SLOT_PERIOD = 1e-3

--- The TimerWheel class
-- Represents a hierarchical timing wheel.
-- @type TimerWheel
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

local function make_timer_entry(t, obj)
    local ent = new_timer_entry()
    ent.time, ent.obj = t, obj
    return ent
end

local function recycle_timer_entry(ent)
    ent.time, ent.next, ent.prev, ent.obj = false, false, false, false
    timer_entry_freelist[#timer_entry_freelist+1] = ent
end

local function new_slots()
    local ret = {}
    for slot=0,WHEEL_SLOTS-1 do
        local head = make_timer_entry(false, false)
        head.prev, head.next = head, head
        ret[slot] = head
    end
    return ret
end

--- Creates a new TimerWheel with the given time and period.
-- @function new_timer_wheel
-- @tparam number now (optional) The starting time for the timer wheel. Default is the current time.
-- @tparam number period (optional) The period for the timer wheel. Default is WHEEL_SLOT_PERIOD.
-- @treturn TimerWheel A new TimerWheel.
local function new_timer_wheel(now, period)
    now, period = now or sc.monotime(), period or WHEEL_SLOT_PERIOD
    return setmetatable(
        { now=now, period=period, rate=1/period, cur=0,
          slots=new_slots(), outer=false }, TimerWheel)
end

local function add_wheel(inner)
    local base = inner.now + inner.period * (WHEEL_SLOTS - inner.cur)
    inner.outer = new_timer_wheel(base, inner.period * WHEEL_SLOTS)
end

--- Adds an event to the timer wheel to be triggered after the given delta time.
-- @tparam number dt The time after which to trigger the event.
-- @param obj The event to trigger.
-- @return The timer entry for the event.
function TimerWheel:add_delta(dt, obj)
    return self:add_absolute(self.now + dt, obj)
end

--- Adds an event to the timer wheel to be triggered at the given absolute time.
-- If the event cannot be scheduled on the current wheel, it's passed to an outer wheel.
-- @tparam number t The time at which to trigger the event.
-- @param obj The event to trigger.
-- @return The timer entry for the event.
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

local function slot_min_time(head)
    local min = 1/0
    local ent = head.next
    while ent ~= head do
        min = math.min(ent.time, min)
        ent = ent.next
    end
    return min
end

--- Returns the time of the next event in the timer wheel.
-- @return The time of the next event.
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

--- Advances the timer wheel by a fixed time in seconds.
-- @tparam number t The time to advance the wheel by.
-- @tparam table sched The scheduler for the wheel.
function TimerWheel:advance(t, sched)
    while t >= self.now + self.period do tick(self, sched) end
end

--- @export
return {
    new_timer_wheel = new_timer_wheel
}