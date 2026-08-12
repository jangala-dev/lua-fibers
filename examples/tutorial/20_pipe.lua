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
local SimulatedHost = require('examples.support.simulated_host')
local file = require('fibers.file')

-- The example support simulator supplies a deterministic linked pipe.
-- Native host families create non-blocking operating-system pipes instead.
fibers.run(function()
  local reader, writer = file.pipe({ label = 'example-pipe' })
  assert(reader)

  fibers.spawn(function()
    fibers.perform(writer:write_op('hello through a pipe'))
    writer:close('writer complete')
  end):label('pipe-writer')

  local bytes = assert(fibers.perform(reader:read_all_op({ max = 1024 })))
  assert(bytes == 'hello through a pipe')
  reader:close('reader complete')
end, { host = SimulatedHost.new({ pipes = true, auto_advance_time = false }) })
