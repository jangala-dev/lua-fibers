package.path = "../../src/?.lua;../?.lua;" .. package.path

-- Importing the necessary modules
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'
local queues = require 'fibers.queue'
local socket = require 'fibers.stream.socket'
local file = require 'fibers.stream.file'
local cond = require 'fibers.cond'
local sc = require 'fibers.utils.syscall'

local perform, choice = fibers.perform, fibers.choice

require("fibers.pollio").install_poll_io_handler()

-- Set up the queues, channel and condition variable
local data_q = queues.new()
local notif_chan = channel.new()
local exit_cond = cond.new()

-- Data Producer fiber
local function producer()
    while true do
        -- sleep for some time to simulate work
        sleep.sleep(math.random())
        -- Send data to the queue
        data_q:put(os.date('%Y-%m-%d %H:%M:%S'))
    end
end

-- Notifier fiber
local function notifier()
    while true do
        -- sleep for some time to simulate work
        sleep.sleep(4 * math.random())
        -- Send data to the channel
        notif_chan:put(1)
    end
end

-- Exit signaller
local function exit()
    while true do
        -- sleep for some time to simulate work
        sleep.sleep(30 * math.random())
        -- Signal the condition
        exit_cond:signal()
    end
end

-- Consumer fiber
local function consumer()
    -- file to write data to
    local filename = "/tmp/data.txt"
    os.execute("rm "..filename)
    local tempfile = assert(file.open(filename, 'w'))
    -- socket setup
    local sockname = '/tmp/test-socket'
    os.execute("rm "..sockname)
    socket.socket(sc.AF_UNIX, sc.SOCK_STREAM, 0):listen_unix(sockname)
    local sock = socket.connect_unix(sockname)
    while true do
        -- Use choice to handle multiple potentially blocking actions
        local task = choice(
            data_q:get_op():wrap(function(value)
                print("data received - writing to socket")
                sock:write(value .. "\n")
                sock:flush_output()
            end),
            notif_chan:get_op():wrap(function(value)
                print("notification received - writing to file")
                tempfile:write(value .. "\n")
                tempfile:flush_output()
            end),
            exit_cond:wait_op():wrap(function()
                print("EXIT SIGNAL RECEIVED")
                os.exit()
            end),
            sleep.sleep_op(0.5):wrap(function()
                print("yawn - nothing happening")
            end)
        )
        perform(task)
    end
end

local function main()
    fibers.spawn(producer)
    fibers.spawn(notifier)
    fibers.spawn(exit)
    consumer()
end

fibers.run(main)
