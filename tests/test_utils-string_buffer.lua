--- Tests the Buffer implementation.
print('testing: fibers.utils.string_buffer')

-- look one level up
package.path = "../?.lua;" .. package.path

local bytes_buffer = require 'fibers.utils.string_buffer'

local buf = bytes_buffer.new(8) -- small size to force a grow operation soon

-- Writing data to fill the buffer

buf:write("ABCDEFGH")

assert(buf:len() == 8, "Expected length 8 after writes")
assert(buf:cap() == 8, "Expected capacity 8 initially")



-- Trigger the grow function by writing more data
buf:write("IJKL")

assert(buf:len() == 12, "Expected length 12 after additional writes")
assert(buf:cap() >= 12, "Expected increased capacity after grow")

-- Reading back data to ensure integrity
local read1 = buf:next(4) -- Reading 4 bytes
assert(read1 == "ABCD", "Expected 'ABCD' from buffer read")

local read2 = buf:next(8) -- Reading the next 8 bytes
assert(read2 == "EFGHIJKL", "Expected 'EFGHIJKL' from buffer read")

print("All tests passed!")
