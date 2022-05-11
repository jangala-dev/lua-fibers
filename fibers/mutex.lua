-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Mutexes following the functionality of those in golang. Inspired by
--
--  https://towardsdev.com/golang-using-buffered-channel-like-a-mutex-9c7c80ec5c27

package.path = '../?.lua;' .. package.path

local queue = require 'fibers.queue'
local op = require 'fibers.op'

local function new()
    local q = queue.new(1)
    local ret = {}
    function ret:lock_operation() return q:put_operation(1) end
    function ret:lock() self:lock_operation():perform() end
    function ret:unlock_operation() return q:get_operation() end
    function ret:unlock()
        local function error_func()
            print("panic: unlock of unlocked mutex\n",debug.traceback())
            os.exit()
        end
        self:unlock_operation()
            :perform_alt(op.default_op():wrap(error_func))
    end
    function ret:trylock()
        local function failure_op() return false end
        return self:lock_operation()
            :wrap(function() return true end)
            :perform_alt(op.default_op():wrap(failure_op))
    end
    return ret
end

return {
    new = new,
}