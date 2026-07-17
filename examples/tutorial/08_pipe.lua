package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Host = require('fibers.host')
local file = require('fibers.file')

-- ManualHost supplies a deterministic linked pipe for this portable example.
-- Native host families create non-blocking operating-system pipes instead.
fibers.run(function()
  local reader, writer = fibers.perform(file.pipe_op({ name = 'example-pipe' }))
  assert(reader)

  fibers.spawn(function()
    fibers.perform(writer:write_op('hello through a pipe'))
    fibers.perform(writer:close_op('writer complete'))
  end, 'pipe-writer')

  local bytes = assert(fibers.perform(reader:read_all_op({ max = 1024 })))
  assert(bytes == 'hello through a pipe')
  fibers.perform(reader:close_op('reader complete'))
end, { host = Host.manual({ pipes = true, auto_advance_time = false }) })
