package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- An embedded plugin and its native host communicate through an owned in-memory
-- stream. The same shape can later sit behind LuaJIT, Luau or WASM boundaries.

local fibers = require('fibers')
local Stream = require('fibers.stream')

local plugin_end, host_end = Stream.memory_pair({ name = 'plugin-control-stream', capacity = 64 })
local line, eof, eof_err

fibers.run(function(scope)
  scope:spawn(function()
    fibers.perform(plugin_end:writer():write_op('INDEX_READY\n'))
    fibers.perform(plugin_end:shutdown_write_op())
  end, 'embedded-plugin')

  line = fibers.perform(host_end:reader():read_line_op())
  eof, eof_err = fibers.perform(host_end:reader():read_some_op(1024))
end)

assert(line == 'INDEX_READY')
assert(eof == nil and eof_err == 'eof')
print('plugin message:', line)
