
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- A simple implementation of waitgroups as in golang.

package.path = '../?.lua;' .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local go = require 'fibers.go'

local function new()
   local done_ch, inc_ch = channel.new(), channel.new()
   local function wg_manager()
      local waiting = 0
      while true do
         local inc = inc_ch:get()
         waiting = waiting + inc
         if waiting == 0 then
            done_ch:put(true)
         end
      end
   end
   fiber.spawn(wg_manager)
   local ret = {}
   function ret:add(x) inc_ch:put(x or 1) end
   function ret:done() inc_ch:put(-1) end
   function ret:wait() done_ch:get() end
   return ret
end

local function selftest()
   print('selftest: fibers.waitgroup')
   local function main()
      local num_workers = 10000
      local function worker()
         sleep.sleep(math.random())
      end
      local wg = new()
      local final_complete = false
      for i=1,num_workers do
         wg:add()
         go(function()
            worker()
            wg:done()
            if i == num_workers then final_complete = true end
         end)
      end
      wg:wait()
      assert(final_complete)
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