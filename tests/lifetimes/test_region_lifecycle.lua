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
local FibersRegion = require('fibers.region')
local Settlement = require('fibers.region.settlement')
assert(FibersRegion.resolve_claim_op == nil, 'resolve_claim_op should be absent')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end

-- Region lifecycle is explicit: live -> claimed -> live, followed by settlement-driven retirement.
do
  local region = FibersRegion.new('lifecycle-region')
  local h = FibersRegion.handle('lifecycle-owned')
  local phases = {}
  local owner_after_retirement
  fibers.run(function()
    fibers.perform(region:admit_op(h))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase

    local claim = fibers.perform(region:claim_op(h, { type = 'test', reason = 'claim-restore' }))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase
    fibers.perform(claim:restore_op())
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase

    fibers.perform(Settlement.retire_item_op(region, h, 'test retirement'))
    owner_after_retirement = h.owner
    assert_eq(fibers.perform(region:record_op(h)), nil, 'retired record should be absent')
  end)
  assert_eq(phases[1], 'live', 'admitted record should be live')
  assert_eq(phases[2], 'claimed', 'claim should mark record claimed')
  assert_eq(phases[3], 'live', 'pristine restoration should return record to live')
  assert_eq(owner_after_retirement, nil, 'settlement should release ownership')
end

-- Movement and ownership remain explicit lifecycle operations.
do
  local region = FibersRegion.new('lifecycle-move-region')
  local h = FibersRegion.handle('lifecycle-move-owned')
  local moved, owned_by_to
  fibers.run(function()
    local to = FibersRegion.new('lifecycle-move-target')
    fibers.perform(region:admit_op(h))
    fibers.perform(region:move_op(h, to))
    moved = h.owner == to
    owned_by_to = fibers.perform(to:owns_op(h))
  end)
  assert_eq(moved, true, 'move_op should transfer owner')
  assert_eq(owned_by_to, true, 'target should own moved item')
end

print('tests/test_region_lifecycle.lua: ok')
