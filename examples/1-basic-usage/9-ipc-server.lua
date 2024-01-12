--[[
    This code demos how we can monitor sockets for IPC showing a server that 
    can handle multiple clients.
]]

package.path = "../../?.lua;../?.lua;" .. package.path

-- Importing necessary modules
local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local socket = require 'fibers.stream.socket'
local sc = require 'fibers.utils.syscall'

-- Install a polling I/O handler from the fibers library
require("fibers.pollio").install_poll_io_handler()

-- Define the path for the Unix domain socket
local sockname = '/tmp/ntpd-sock'

-- Remove the socket file if it already exists to avoid 'address already in use' errors
sc.unlink(sockname)

-- Create and start listening on the Unix domain socket
local server = assert(socket.listen_unix(sockname))

-- Spawn a fiber to handle incoming connections
fiber.spawn(function ()
    while true do
        -- Accept a new connection
        local peer = assert(server:accept())

        -- Spawn a new fiber for each connection to handle client communication
        fiber.spawn(function()
            while true do
                -- Read a line from the connected client
                local rec = peer:read_line()

                -- If a line is received, process it
                if rec then
                    print("received:", rec)
                    -- Check for a specific command ('exit!') to shut down the server
                    if rec == "exit!" then 
                        print("shut down command received") 
                        break 
                    end
                else
                    -- If no data is received (client closed the connection), break the loop
                    break 
                end
            end
            -- Close the connection to the client
            peer:close()
        end)
    end
    -- After the server is stopped, remove the socket file and stop the fiber
    sc.unlink(sockname)
    fiber.stop()
end)

-- Spawn another fiber to periodically print a heartbeat message
fiber.spawn(function ()
    while true do
        print("hb")
        -- Sleep for 1 second before printing the next heartbeat
        sleep.sleep(1)
    end
end)

-- Start the main fiber loop
fiber.main()
