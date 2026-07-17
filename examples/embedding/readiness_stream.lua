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
local Runtime = require('fibers.runtime')
local Region = require('fibers.lifetime.region')
local Stream = require('fibers.stream')

local rt = Runtime.new()
local region = Region.new('readiness-example')
local backend = require('fibers.stream.backend.fake').new({
  name = 'readiness-example-backend',
  readiness = 'manual',
  initial_writable = false,
  write_blocked = true,
})

local stream, line, flushed

rt:spawn_raw(function()
  stream = rt:perform(
    Stream.open_op(backend, { owner = region, read = true, write = true, name = 'readiness-example-stream' })
  )
  rt:perform(stream:writer():write_op('ping\n'))
  flushed = rt:perform(stream:writer():flush_op())
  line = rt:perform(stream:reader():read_line_op())
end, 'root')

-- Opening commits stream ownership and reactor registrations, but write readiness has not
-- arrived yet, so nothing has reached the backend.
rt:run()
assert(backend:written() == '')

-- A host adapter would call this when the handle becomes writable.
backend:unblock_writes()
rt:run()
assert(flushed == true)
assert(backend:written() == 'ping\n')

-- Host input is separate from readiness delivery.
backend:feed_read('pong\n')
backend:mark_readable()
rt:run()
assert(line == 'pong')

print('examples/embedding/readiness_stream.lua: ok')
