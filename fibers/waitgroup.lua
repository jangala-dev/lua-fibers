
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- A simple implementation of waitgroups as in golang.

package.path = '../?.lua;' .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local cond = require 'fibers.cond'

local function new()
   local inc_ch = channel.new()
   local at_zero = cond.new()
   local waiting = 0
   fiber.spawn(function()
         while true do
            waiting = waiting + inc_ch:get()
            if waiting == 0 then
               at_zero:signal()
            end
         end
      end)
   local ret = {}
   function ret:add(x) inc_ch:put(x) end
   function ret:done() inc_ch:put(-1) end
   function ret:wait() if waiting > 0 then at_zero:wait() end end
   return ret
end

local function selftest()
   local sleep = require 'fibers.sleep'
   local go = require 'fibers.go'
   print('selftest: fibers.waitgroup')
   local num_routines = 5000

   local function main()
      local wg1 = new()
      local wg2 = new()

      -- newly initialisaed waitgroups don't block on wait
      wg1:wait()
      wg2:wait()
      
      -- test adding higher numbers to the waitgroup
      wg1:add(2)
      go(function()
         sleep.sleep(1)
         wg1:add(-2)
      end)

      for i=1,num_routines do
         wg2:add(1)
         go(function ()
            wg1:wait()
            sleep.sleep(1)
            wg2:done()
         end)
      end

      wg2:wait()
      print('selftest: ok')
   end

   go(function()
      main()
      fiber.current_scheduler:stop()
   end)
   fiber.current_scheduler:main()
end

return {
    new = new,
    selftest = selftest
}