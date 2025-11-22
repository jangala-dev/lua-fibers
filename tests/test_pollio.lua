--- Tests the File implementation.
print('testing: fibers.fd')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local pollio = require 'fibers.pollio'
local file_stream = require 'fibers.stream.file'
local runtime = require 'fibers.runtime'

local equal = require 'fibers.utils.helper'.equal
local log = {}
local function record(x) table.insert(log, x) end

-- local handler = new_poll_io_handler()
-- file.set_blocking_handler(handler)
-- runtime.current_scheduler:add_task_source(handler)
pollio.install_poll_io_handler()

runtime.current_scheduler:run()
assert(equal(log, {}))

local rd, wr = file_stream.pipe()
local message = "hello, world\n"
runtime.spawn_raw(function()
    record('rd-a')
    local str = rd:read_some_chars()
    record('rd-b')
    record(str)
end)
runtime.spawn_raw(function()
    record('wr-a')
    wr:write(message)
    record('wr-b')
    wr:flush()
    record('wr-c')
end)

runtime.current_scheduler:run()
assert(equal(log, { 'rd-a', 'wr-a', 'wr-b', 'wr-c' }))
runtime.current_scheduler:run()
assert(equal(log, { 'rd-a', 'wr-a', 'wr-b', 'wr-c', 'rd-b', message }))

print('test: ok')
