package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

-- Resource-author Closure in miniature. A resource is born with a dormant
-- Lifetime. Admission makes that Lifetime a child of the Scope; closing it
-- requests and finishes the complete subtree.

local fibers = require('fibers')
local Lifetime = require('fibers.lifetime')
local Cell = require('fibers.resource.cell')
local Closure = require('fibers.closure')

local closed = Cell.new(false):label('demo-handle-closed')
local handle = { name = 'demo-handle' }
Lifetime.define(handle, {
  role = 'demo-handle',
  closure = Closure.protocol({
    name = 'demo-close',
    finish_op = function(_ctx, entry, close)
      return closed:write_op({
        closed = true,
        resource = entry.item.name,
        reason = close.reason,
      })
    end,
  }),
})

local finished, lifetime_closed
local result = fibers.try_run(function(scope)
  fibers.perform(scope:admit_op(handle))
  scope:retire(handle, 'done')
  finished = fibers.perform(closed:read_op())
  lifetime_closed = fibers.perform(Lifetime.of(handle):retired_op()) == Lifetime.of(handle)
end)

assert(result.runtime_status.tag == 'found')
assert(finished.closed == true)
assert(finished.resource == 'demo-handle')
assert(finished.reason == 'done')
assert(lifetime_closed)

print('examples/lifetimes/resource_closure.lua: ok')
