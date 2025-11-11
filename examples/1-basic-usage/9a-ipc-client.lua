package.path = "../?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

package.path = "../../src/?.lua;../?.lua;" .. package.path

-- Importing necessary modules
local fibers = require "fibers"
local socket = require 'fibers.stream.socket'

-- Install a polling I/O handler from the fibers library
require("fibers.pollio").install_poll_io_handler()

-- The first argument is the JSON string
local json_str = arg[1]

-- Define the path for the Unix domain socket
local sockname = '/tmp/ntpd-sock'

local function main()
    local client = socket.connect_unix(sockname)
    client:setvbuf('no')

    client:write(json_str)

    client:close()
end

-- Start the main fiber loop
fibers.run(main)
