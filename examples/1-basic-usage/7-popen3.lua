-- usage of the fibers.stream.file.popen3 function

package.path = "../../?.lua;../?.lua;" .. package.path

local file = require 'fibers.stream.file'
local fiber = require 'fibers.fiber'

local function main()
   local pid, in_st, out_st, _ = file.popen3('cat', {})
   in_st:setvbuf('line')
   local msg1 = "Hello\n"
   local msg2 = "World\n"
   in_st:write(msg1)
   in_st:write(msg2)
   fiber.spawn(function()
      for line in out_st:lines() do
         print(line)
      end
   end)
end

require 'fibers.file'.install_poll_io_handler()
fiber.spawn(main)
fiber.main()

