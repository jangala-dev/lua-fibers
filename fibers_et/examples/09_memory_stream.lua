package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Stream = fibers.Stream

local a, b = Stream.memory_pair({ name = 'example-stream', capacity = 64 })
local line, eof, eof_err

local st = fibers.run(function()
  fibers.spawn_raw(function()
    fibers.perform(a:writer():write_op('hello stream\n'))
    fibers.perform(a:writer():shutdown_op())
  end, 'writer')

  line = fibers.perform(b:reader():read_line_op())
  eof, eof_err = fibers.perform(b:reader():read_some_op(1024))
end)

assert(st.tag == 'found')
assert(line == 'hello stream')
assert(eof == nil and eof_err == 'eof')
print('examples/09_memory_stream.lua: ok')
