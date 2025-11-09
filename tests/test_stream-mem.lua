--- Tests the Stream Mem implementation.
print('testing: fibers.stream.mem')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local mem = require 'fibers.stream.mem'
local sc = require 'fibers.utils.syscall'

local str = "hello, world!"
local stream = mem.open_input_string(str)
assert(stream:seek() == 0)
assert(stream:seek(sc.SEEK_END) == #str)
assert(stream:seek() == #str)
assert(stream:seek(sc.SEEK_SET) == 0)
assert(stream:read_all_chars() == str)
assert(not pcall(stream.write_chars, stream, "more chars"))
assert(stream:seek() == #str)
stream:close()

stream = mem.tmpfile()
assert(stream:seek() == 0)
assert(stream:seek(sc.SEEK_END) == 0)
stream:write_chars(str)
stream:flush()
assert(stream:seek() == #str)
assert(stream:seek(sc.SEEK_SET) == 0)
assert(stream:read_all_chars() == str)
stream:close()
print('selftest: ok')
