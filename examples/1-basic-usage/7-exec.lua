-- usage of the fibers.exec module

package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local exec = require 'fibers.exec'
local pollio = require 'fibers.pollio'

pollio.install_poll_io_handler()

local function main()
   fiber.spawn(function () -- long running process where we want to periodically deal with output
      local cmd = exec.command('cat')
      local stdin_pipe = assert(cmd:stdin_pipe())
      local stdout_pipe = assert(cmd:stdout_pipe())
      local err = cmd:start()
      if err then error(err) end
      fiber.spawn(function ()
         for i=1,4 do
            stdin_pipe:write('tick\n')
            sleep.sleep(0.2)
         end
         stdin_pipe:write('BOOM!\n')
         stdin_pipe:close()
      end)
      while true do
         local received = stdout_pipe:read_line()
         if not received then break end
         print(received)
      end
      local err = cmd:wait() -- gets exit code, etc
      if err then error(err) end
      print("ticker exited with exit code:", cmd.process_state.ssi_status)
   end)
   -- simple command where we want to simply gather all output
   print("starting combined command")
   local output, err = exec.command('sh', '-c', 'sleep 1; echo hello world; exit 255'):combined_output()
   assert(err, "expected error!")
   print("output:", output)
   fiber.stop()
end

fiber.spawn(main)
fiber.main()

