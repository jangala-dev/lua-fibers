package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Stream = require('fibers.stream')

local a, b = Stream.memory_pair({ name = 'example-stream', capacity = 64 })
local line, eof, eof_err

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(a:writer():write_op('hello stream\n'))
    fibers.perform(a:writer():shutdown_op())
  end, 'writer')

  line = fibers.perform(b:reader():read_line_op())
  eof, eof_err = fibers.perform(b:reader():read_some_op(1024))
end)

assert(line == 'hello stream')
assert(eof == nil and eof_err == 'eof')
print('examples/tutorial/06_memory_stream.lua: ok')
