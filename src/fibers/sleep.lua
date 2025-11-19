-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.sleep module.
-- Provides functions to suspend execution of fibers for a certain duration (sleep) or until a specific time.
-- @module fibers.sleep

local op = require 'fibers.op'
local runtime = require 'fibers.runtime'

local perform = require 'fibers.performer'.perform

-- Primitive: wait until absolute time `t`.
local function deadline_op(t)
    local function try()
        return runtime.now() >= t
    end
    local function block(suspension, wrap_fn)
        suspension.sched:schedule_at_time(t, suspension:complete_task(wrap_fn))
    end
    return op.new_primitive(nil, try, block)
end

--- Create a new operation that puts the current fiber to sleep until the time t.
-- @tparam number t The time to sleep until.
-- @treturn operation The created operation.
local function sleep_until_op(t)
    return deadline_op(t)
end

--- Put the current fiber to sleep until time t.
-- @tparam number t The time to sleep until.
local function sleep_until(t)
    return perform(sleep_until_op(t))
end

--- Create a new operation that puts the current fiber to sleep for a duration dt.
-- @tparam number dt The duration to sleep.
-- @treturn operation The created operation.
local function sleep_op(dt)
    return op.guard(function()
        return deadline_op(runtime.now() + dt)
    end)
end

--- Put the current fiber to sleep for a duration dt.
-- @tparam number dt The duration to sleep.
local function sleep(dt)
    return perform(sleep_op(dt))
end

return {
    sleep          = sleep,
    sleep_op       = sleep_op,
    sleep_until    = sleep_until,
    sleep_until_op = sleep_until_op,
}
