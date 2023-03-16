local op = require "fibers.op"

-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- A simple implementation of waitgroups as in golang.

package.path = '../?.lua;' .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local cond = require 'fibers.cond'

local function new()
   local inc_ch, wait_ch = channel.new(), channel.new()
   local at_zero = cond.new()
   fiber.spawn(function()
        local wait_count = 0
        local function inc(x)
            wait_count = wait_count + x
            if wait_count == 0 then
                at_zero:signal()
            elseif wait_count < 0 then
                print(debug.traceback())
                os.exit()
            end
        end
        while true do
            op.choice(
                inc_ch:get_operation():wrap(inc),
                wait_ch:put_operation(wait_count>0)
            ):perform()
        end
      end)
   local ret = {}
   function ret:add(x) inc_ch:put(x) end
   function ret:done() self:add(-1) end
   function ret:wait_operation()
      if wait_ch:get() then
         return at_zero:wait_operation()
      else
         return op.default_op()
      end
   end
   function ret:wait() return self:wait_operation():perform() end
   return ret
end

return {
    new = new,
}