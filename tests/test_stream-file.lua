--- Tests the Stream File implementation.
print('testing: fibers.stream.file')

-- look one level up
package.path = "../?.lua;" .. package.path

local file = require 'fibers.stream.file'

local rd, wr = file.pipe()
local message = "hello, world\n"

wr:setvbuf('line')
wr:write(message)
local message2 = rd:read_some_chars()
assert(message == message2)
wr:close()
assert(rd:read_some_chars() == nil)
rd:close()

local subprocess = file.popen('echo "hello"; echo "world"', 'r')
local lines = {}
for line in subprocess:lines() do table.insert(lines, line) end
local res, exit_type, code = subprocess:close()
assert(res)
assert(exit_type == "exit")
assert(code == 0)
assert(#lines == 2)
assert(lines[1] == 'hello')
assert(lines[2] == 'world')

print('test: ok')
