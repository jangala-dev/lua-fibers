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

-- Resource-author settlement in miniature.
--
-- Ordinary code should normally use facilities such as Scope, Task and
-- Stream.  Resource authors can admit an Owned value with an Op-valued
-- settlement protocol.  Retirement claims the item, runs that protocol, then
-- releases the ownership record.

local fibers = require('fibers')
local Scalar = require('fibers.scalar')
local Region = require('fibers.lifetime.region')
local Scope = require('fibers.scope')


local Owned = Region.Owned

local Settlement = require('fibers.internal.settlement')

local scope = Scope.new('owned-resource-example')
local closed = Scalar.new(false, 'demo-handle-closed')
local handle = Region.handle('demo-handle')

local owned = Owned.item(handle, function(_ctx, record, claim)
  return closed:write_op({
    closed = true,
    item = record.item,
    claim_id = claim.id,
    reason = claim.reason,
  })
end, {
  role = 'demo-handle',
  settle_name = 'demo-close',
})

local settled
local st = fibers.try_run(function()
  fibers.perform(scope:raw_region():admit_op(owned))
  fibers.perform(Settlement.retire_item_op(scope, handle, 'done'))
  settled = fibers.perform(closed:read_op())
end).runtime_status

assert(st.tag == 'found')
assert(settled.closed == true)
assert(settled.item == handle)
assert(settled.reason == 'done')
assert(handle.owner == nil)

print('examples/lifetimes/owned_resource_settlement.lua: ok')
