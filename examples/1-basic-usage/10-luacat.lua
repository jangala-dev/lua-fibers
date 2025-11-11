package.path = "../../src/?.lua;../?.lua;" .. package.path

-- Importing the necessary modules from the fibers framework
local fibers = require 'fibers'
local file = require 'fibers.stream.file'
local socket = require 'fibers.stream.socket'
local sc = require 'fibers.utils.syscall'

require("fibers.pollio").install_poll_io_handler()

-- Open stdin for reading
local stdin = assert(file.fdopen(sc.STDIN_FILENO, sc.O_RDONLY))

-- Get the socket path from the first argument
local socketPath = arg[1]
if not socketPath then
    error("Socket path not provided")
end

-- Connect to the Unix domain socket
local sock = socket.connect_unix(socketPath)

-- Fiber to read from stdin and write to the socket
local function main()
    while true do
        local line = stdin:read('*l')
        if line then
            sock:write(line .. "\n")
            sock:flush_output()
        else
            -- End of input
            break
        end
    end
    -- Close the socket once done
    stdin:close()
    sock:close()
end

-- Start the main fiber loop
fibers.run(main)
