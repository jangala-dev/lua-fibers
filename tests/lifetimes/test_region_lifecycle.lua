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
local FibersRegion = require('fibers.lifetime.region')
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

-- Region lifecycle is explicit: live -> claimed -> live/failed/retired.
do
  local region = FibersRegion.new('lifecycle-region')
  local h = FibersRegion.handle('lifecycle-owned')
  local phases = {}
  local owner_after_discharge
  fibers.run(function()
    fibers.perform(region:admit_op(h))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase

    local c1 = fibers.perform(region:claim_op(h, { type = 'test', reason = 'claim-restore' }))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase
    fibers.perform(region:resolve_op(c1, { kind = 'restore' }))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase

    local c2 = fibers.perform(region:claim_op(h, { type = 'test', reason = 'claim-fail' }))
    fibers.perform(region:resolve_op(c2, { kind = 'fail', error = 'boom' }))
    local failed = fibers.perform(region:record_op(h))
    phases[#phases + 1] = failed.phase
    assert_truthy(failed.settlement_failed, 'failed resolution should mark settlement_failed')
    assert_truthy(
      tostring(failed.settlement_error_message):match('boom'),
      'failed resolution should retain error message'
    )

    fibers.perform(region:resolve_op(c2, { kind = 'restore' }))
    phases[#phases + 1] = fibers.perform(region:record_op(h)).phase

    local c3 = fibers.perform(region:claim_op(h, { type = 'test', reason = 'claim-discharge' }))
    fibers.perform(region:resolve_op(c3, { kind = 'discharge' }))
    owner_after_discharge = h.owner
    assert_eq(fibers.perform(region:record_op(h)), nil, 'discharged record should be absent')
  end)
  assert_eq(phases[1], 'live', 'admitted record should be live')
  assert_eq(phases[2], 'claimed', 'claim should mark record claimed')
  assert_eq(phases[3], 'live', 'restore should return record to live')
  assert_eq(phases[4], 'failed', 'failed resolution should mark record failed')
  assert_eq(phases[5], 'live', 'failed claim may be restored explicitly')
  assert_eq(owner_after_discharge, nil, 'discharge should release ownership')
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
