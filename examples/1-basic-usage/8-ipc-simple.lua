-- demonstrates IPC using exec and non-blocking sockets

package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require "fibers.fiber"
local exec = require "fibers.exec"
local sleep = require "fibers.sleep"
local socket = require 'fibers.stream.socket'
local sc = require 'fibers.utils.syscall'

require("fibers.pollio").install_poll_io_handler()

local sockname = '/tmp/test-sock'

sc.unlink(sockname)
local server = assert(socket.listen_unix(sockname))

fiber.spawn(function ()

    sleep.sleep(2) -- to show that things don't block and are gracefully buffered by sockets

    while true do
         local peer = assert(server:accept())
         local rec = peer:read_line()
         peer:close()
         print("received:", rec)
         if rec  == "exit!" then print "shut down command received" break end
    end
    sc.unlink(sockname)
    fiber.stop()
end)

fiber.spawn(function ()
   local messages = {"apple", "pear", "exit!"}
   for _, v in ipairs(messages) do
      print("sending:", v)
      -- use the netcat command `nc` to write to a unix domain socket
      local command = 'echo "'..v..'" | nc -U '..sockname
      local out, err = exec.command('sh', '-c', command):combined_output()
      if err then error(out) end
   end
end)

fiber.spawn(function ()
   while true do
      print("hb")
      sleep.sleep(1)
   end
end)

fiber.main()
