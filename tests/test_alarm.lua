-- test_alarm.lua
--
-- Simple demonstration of fibers.alarm with guard + named_choice.

print('testing: fibers.alarm')

package.path = "../src/?.lua;" .. package.path

local runtime  = require 'fibers.runtime'
local perform  = require 'fibers.performer'.perform
local op       = require 'fibers.op'
local alarmmod = require 'fibers.alarm'

local function main()
    -- Two one-shot alarms at the same time.
    local a1 = alarmmod.after(1.0)
    local a2 = alarmmod.after(1.0)

    -- One repeating alarm: first fire after 0.5s, then every 0.5s.
    local a3 = alarmmod.every(0.5)

    runtime.spawn_raw(function()
        local function build_arms()
            local arms = {}

            if a1:is_active() then
                arms.a1 = a1:event():wrap(function(al, ...)
                    return "a1", al, ...
                end)
            end

            if a2:is_active() then
                arms.a2 = a2:event():wrap(function(al, ...)
                    return "a2", al, ...
                end)
            end

            if a3:is_active() then
                arms.a3 = a3:event():wrap(function(al, ...)
                    return "a3", al, ...
                end)
            end

            return arms
        end

        -- A single dynamic event that, on each synchronisation,
        -- chooses one of the currently-active alarms.
        local ev = op.guard(function()
            local arms = build_arms()
            if next(arms) == nil then
                return op.never()
            else
                return op.named_choice(arms)
            end
        end)

        -- Run until both one-shot alarms have fired; then stop
        -- the scheduler. The repeating alarm will still be active
        -- but we ignore it after that.
        while true do
            local name, al = perform(ev)
            local t = runtime.now()
            print(("[%.3f] alarm %s fired"):format(t, name))

            if not a1:is_active() and not a2:is_active() then
                print("Both one-shot alarms have fired; stopping runtime.")
                runtime.stop()
                break
            end
        end
    end)

    runtime.main()
end

-- Allow this file to be run directly (e.g. `lua test_alarm.lua`)
-- or required from elsewhere.
if ... == nil then
    main()
else
    return {
        main = main,
    }
end
