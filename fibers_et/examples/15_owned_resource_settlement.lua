package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

-- Resource-author settlement in miniature.
--
-- Ordinary code should normally use facilities such as Lifetime, Task and
-- Stream.  Resource authors can admit an Owned value with an Op-valued
-- settlement protocol.  Retirement claims the item, runs that protocol, then
-- releases the ownership record.

local fibers = require('fibers')

local Lifetime = fibers.Lifetime
local Region = fibers.Region
local Owned = fibers.Region.Owned
local Cell = fibers.Cell

local life = Lifetime.new('owned-resource-example')
local closed = Cell.new(false, 'demo-handle-closed')
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
local st = fibers.run(function()
  fibers.perform(life:raw_region():admit_op(owned))
  fibers.perform(life:settle_item_op(handle, 'done'))
  settled = fibers.perform(closed:read_op())
end)

assert(st.tag == 'found')
assert(settled.closed == true)
assert(settled.item == handle)
assert(settled.reason == 'done')
assert(handle.owner == nil)

print('examples/15_owned_resource_settlement.lua: ok')
