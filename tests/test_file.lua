--- Tests the File implementation.
print('testing: fibers.file')

-- look one level up
package.path = "../?.lua;" .. package.path

local file = require 'fibers.file'
local file_stream = require 'fibers.stream.file'
local fiber = require 'fibers.fiber'

local equal = require 'fibers.utils.helper'.equal
local log = {}
local function record(x) table.insert(log, x) end

-- local handler = new_poll_io_handler()
-- file.set_blocking_handler(handler)
-- fiber.current_scheduler:add_task_source(handler)
file.install_poll_io_handler()

fiber.current_scheduler:run()
assert(equal(log, {}))

local rd, wr = file_stream.pipe()
local message = "hello, world\n"
fiber.spawn(function()
               record('rd-a')
               local str = rd:read_some_chars()
               record('rd-b')
               record(str)
            end)
fiber.spawn(function()
               record('wr-a')
               wr:write(message)
               record('wr-b')
               wr:flush()
               record('wr-c')
            end)

fiber.current_scheduler:run()
assert(equal(log, {'rd-a', 'wr-a', 'wr-b', 'wr-c'}))
fiber.current_scheduler:run()
assert(equal(log, {'rd-a', 'wr-a', 'wr-b', 'wr-c', 'rd-b', message}))

print('test: ok')
