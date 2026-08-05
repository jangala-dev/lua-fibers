-- Portable Luau smoke tests.  The build step rewrites logical module names to
-- aliases and emits this file as build/luau/tests/smoke.luau.

local fibers = require('fibers')
local ManualHost = require('fibers.embed.manual')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')

-- ManualHost exercises the embeddable runtime without filesystem or process
-- facilities from the standalone Luau sandbox.
do
  local rt = Runtime.new({ host = ManualHost.new() })
  local channel = Rendezvous.new():label('luau-smoke')
  local received

  rt:spawn_raw(function()
    received = rt:perform(channel:get_op())
  end):label('receiver')
  rt:spawn_raw(function()
    rt:perform(channel:put_op('ok'))
  end):label('sender')

  local status = rt:run()
  assert(status.tag == 'found')
  assert(received == 'ok')
end

-- The application-facing root lifecycle should work for immediately committable work;
-- no host sleep or native I/O is required.
fibers.run(function()
  local cell = Cell.new(0):label('luau-cell')
  assert(fibers.perform(cell:write_op(1)) == true)
  assert(fibers.perform(cell:read_op()) == 1)
end)

-- Luau may allow a protected function to yield while still prohibiting a
-- yielding xpcall error handler.  Fibers must select its coroutine-backed
-- implementation in that case.
fibers.run(function()
  local channel = Rendezvous.new():label('luau-xpcall-handler')
  fibers.spawn(function()
    fibers.perform(channel:put_op('handled'))
  end):label('handler-sender')

  local ok, value = fibers.xpcall(function()
    error('luau-handler-error')
  end, function(err)
    return fibers.perform(channel:get_op()) .. ':' .. tostring(err)
  end)
  assert(ok == false)
  assert(string.find(value, 'handled:', 1, true) == 1)
end)

-- Fibers relies on table-valued errors for cancellation and structured failure.
-- Keep this as a conformance gate before promoting Luau into the main matrix.
do
  local marker = { kind = 'luau-error-marker' }
  local ok, err = fibers.pcall(function()
    error(marker)
  end)
  assert(ok == false)
  assert(err == marker, 'Luau must preserve table-valued errors through fibers.pcall')
end

print('tests/luau/smoke.lua: ok')
