
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- A simple implementation of waitgroups as in golang.

package.path = '../?.lua;' .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local go = require 'fibers.go'
local op = require 'fibers.op'

local function new()
   local done_ch, inc_ch = channel.new(), channel.new()
   local function closer()
      local waiting = 0
      local to_be_closed = {}
      while true do
         op.choice(
            inc_ch:get_operation():wrap(function(x)
               waiting = waiting + x
               if waiting == 0 then
                  for _, i in ipairs(to_be_closed) do
                     i:put(true)
                  end
                  to_be_closed = {}
               end
            end),
            done_ch:get_operation():wrap(function(x)
               if waiting == 0 then
                  x:put(true)
               else
                  table.insert(to_be_closed,x)
               end
            end)
         ):perform()
      end
   end
   fiber.spawn(closer)
   local ret = {}
   function ret:add(x) inc_ch:put(x) end
   function ret:done() inc_ch:put(-1) end
   function ret:wait() 
      local a = channel.new() 
      done_ch:put(a) 
      a:get()
   end
   return ret
end

local function selftest()
   print('selftest: fibers.waitgroup')
   local num_routines = 1000

   local function main()
      local wg1 = new()
      local wg2 = new()

      -- newly initialisaed waitgroups don't block on wait
      wg1:wait()
      wg2:wait()

      wg1:add(1)
      go(function()
         sleep.sleep(1)
         wg1:done()
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