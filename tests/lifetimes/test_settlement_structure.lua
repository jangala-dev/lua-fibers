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
local Op = require('fibers.op')
local FakeHandle = require('tests.support.fake_handle')
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.region')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.stream')
local Stream = FibersStream
local HostHandle = require('fibers.host.handle')
local Settlement = require('fibers.region.settlement')

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
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

-- Admission of arbitrary bare values is rejected at construction time.  Owned
-- handles may still carry their default inert settlement protocol.
do
  local r = FibersRegion.new('typed-admission')
  local ok = pcall(function()
    r:admit_op({ name = 'raw-table' })
  end)
  assert_eq(ok, false, 'raw admission should require an Owned record or handle settlement')
  local h = FibersRegion.handle('inert')
  local st = fibers.try_run(function()
    fibers.perform(r:admit_op(h))
  end).runtime_status
  assert_status(st, 'found')
  local rec
  fibers.run(function()
    rec = fibers.perform(r:record_op(h))
  end)
  assert_truthy(rec and rec.settle_name == 'none', 'handle admission should record inert settlement protocol')
end

-- A parent with children cannot be released directly. Generic Scope
-- settlement marks the whole subtree claimed, awaits settlement, then releases
-- the subtree atomically.
do
  local life = FibersScope.new('tree-life')
  local backend = FakeHandle.new({ name = 'tree-backend' })
  local stream, direct_release, settled_status
  local st
  st = fibers.try_run(function()
    stream = fibers.perform(
      Stream.open_op(backend, { owner = life:raw_region(), read = true, write = true, name = 'tree-stream' })
    )
    direct_release = fibers.perform(life
      :raw_region()
      :release_op(stream)
      :map(function()
        return 'released'
      end)
      :or_else(Op.always('blocked')))
    fibers.perform(Settlement.retire_item_op(life, stream, 'done'))
    settled_status = fibers.perform(life:inspect_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(direct_release, 'blocked', 'parent release should be blocked while children remain')
  assert_eq(settled_status.owned_count, 0, 'scope should have no remaining owned records')
end

-- Handoff preserves the owned subtree and settlement protocols.
do
  local a = FibersScope.new('move-tree-a')
  local b = FibersScope.new('move-tree-b')
  local backend = FakeHandle.new({ name = 'move-tree-backend' })
  local stream, a_count_after, b_count_after_move, b_count_after_settlement, child_transfer
  local st = fibers.try_run(function()
    stream = fibers.perform(
      Stream.open_op(
        backend,
        { owner = a:raw_region(), read = true, write = true, name = 'move-tree-stream' }
      )
    )
    fibers.perform(a:move_op(stream, b))
    a_count_after = fibers.perform(a:inspect_op()).owned_count
    b_count_after_move = fibers.perform(b:inspect_op()).owned_count
    child_transfer = fibers.perform(b:raw_region()
      :move_op(stream:reader(), a:raw_region())
      :map(function()
        return 'moved-child'
      end)
      :or_else(Op.always('blocked')))
    fibers.perform(Settlement.retire_item_op(b, stream, 'done'))
    b_count_after_settlement = fibers.perform(b:inspect_op()).owned_count
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(a_count_after, 0, 'move should move whole subtree from source')
  assert_truthy(b_count_after_move and b_count_after_move >= 7, 'move should move whole subtree to target')
  assert_eq(child_transfer, 'blocked', 'contained children should not be moved directly')
  assert_eq(b_count_after_settlement, 0, 'settlement should release handed-off subtree')
end

-- Settlement is inline by default.  The initiating perform claims the subtree,
-- runs the settlement protocol masked, and then releases the claim.
do
  local life = FibersScope.new('driver-life')
  local h = FibersRegion.handle('driver-item')
  local count
  local st = fibers.try_run(function()
    fibers.perform(life:raw_region():admit_op(h))
    fibers.perform(Settlement.retire_item_op(life, h, 'done'))
    count = fibers.perform(life:inspect_op()).owned_count
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(count, 0, 'settlement should release item')
end

-- Settlement is now a tree-level state transition.  The initiating request marks
-- the whole owned subtree as claimed before the masked settlement protocol
-- waits and then releases the subtree atomically.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('phase-life')
  local settled, feed = rt:signal('phase-settled')
  local function K(_ctx, _record)
    return settled:wait_op():map(function()
      return true
    end)
  end
  local parent = FibersRegion.handle('phase-parent')
  local child = FibersRegion.handle('phase-child')
  local other = FibersScope.new('phase-other')
  local phase_parent, phase_child, move_during_settle, release_child
  local settle_without_claim, final_owned_count
  local settle_done = false

  rt:spawn_raw(function()
    rt:perform(
      life:raw_region():admit_op(
        FibersRegion.Owned.tree(
          parent,
          K,
          { FibersRegion.Owned.item(child, K, { role = 'child', settle_name = 'phase-test' }) },
          { role = 'parent', settle_name = 'phase-test' }
        )
      )
    )
    rt:perform(Settlement.retire_item_op(life, parent, 'done'))
    settle_done = true
  end, 'phase-settler')

  local st
  for _ = 1, 20 do
    st = rt:run()
    if st.tag == 'pending' then
      break
    end
  end
  assert_status(st, 'pending', 'settlement should wait for settlement signal')

  rt:spawn_raw(function()
    local prec = rt:perform(life:raw_region():record_op(parent))
    local crec = rt:perform(life:raw_region():record_op(child))
    phase_parent = prec and prec.phase
    phase_child = crec and crec.phase
    move_during_settle = rt:perform(life
      :raw_region()
      :move_op(parent, other:raw_region())
      :map(function()
        return 'moved'
      end)
      :or_else(Op.always('blocked')))
    release_child = rt:perform(life
      :raw_region()
      :release_op(child)
      :map(function()
        return 'released-child'
      end)
      :or_else(Op.always('blocked')))
    settle_without_claim = rt:perform(life
      :raw_region()
      :resolve_op(parent, { kind = 'discharge' })
      :map(function()
        return 'settled-tree'
      end)
      :or_else(Op.always('blocked')))
  end, 'phase-monitor')

  for _ = 1, 20 do
    st = rt:run()
    if phase_parent ~= nil and st.tag == 'pending' then
      break
    end
  end
  assert_status(st, 'pending', 'monitor should run while settlement waits')
  assert_eq(phase_parent, 'claimed', 'settle request should mark parent claimed')
  assert_eq(phase_child, 'claimed', 'settle request should mark child claimed')
  assert_eq(move_during_settle, 'blocked', 'claimed subtree should not be handed off')
  assert_eq(release_child, 'blocked', 'contained child should not be released directly')
  assert_eq(settle_without_claim, 'blocked', 'claim settlement requires a valid claim')
  assert_eq(settle_done, false, 'settle perform should still await driver')

  feed:set(true)
  st = rt:run()
  assert_status(st, 'found')
  assert_eq(settle_done, true, 'settlement should complete after settlement')
  fibers.run(function()
    final_owned_count = fibers.perform(life:inspect_op()).owned_count
  end)
  assert_eq(final_owned_count, 0, 'claim settlement should release the subtree')
end

-- Failed settlement is an observable committed ownership state, not silent
-- limbo.  The claim remains real and the item is not released.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('failing-settlement-life')
  local h = FibersRegion.handle('failing-settlement-item')
  rt:spawn_raw(function()
    rt:perform(life:raw_region():admit_op(FibersRegion.Owned.item(h, function()
      error('settlement boom')
    end, { settle_name = 'failing' })))
    rt:perform(Settlement.retire_item_op(life, h, 'retire'))
  end, 'failing-settlement-root')

  local ok, err = pcall(function()
    return rt:run()
  end)
  assert_eq(ok, false, 'settlement protocol failure should fail the waiting task')
  assert_truthy(Settlement.is_failure(err), 'settlement error should be a recovery capability')
  assert_eq(err.item, h)
  assert_eq(err.region, life:raw_region())
  assert_eq(err.claim_id, err.claim.id)
  assert_truthy(tostring(err.error):match('settlement boom'), 'original settlement error should be retained')
  assert_truthy(tostring(err):match('settlement boom'), 'settlement error should be propagated')

  local rec
  fibers.run(function()
    rec = fibers.perform(life:raw_region():record_op(h))
  end)
  assert_truthy(rec, 'failed settlement record should remain visible')
  assert_eq(rec.phase, 'failed')
  assert_eq(rec.settlement_failed, true)
  assert_eq(rec.claim, nil, 'public records must not expose recovery authority')
  assert_eq(rec.claim_id, err.claim_id, 'diagnostic claim id should match the capability')
  assert_truthy(
    tostring(rec.settlement_error_message or ''):match('settlement boom'),
    'record should expose failure message'
  )
  local failed_count
  fibers.run(function()
    failed_count = fibers.perform(life:inspect_op()).owned_count
    fibers.perform(err:restore_op())
    rec = fibers.perform(life:raw_region():record_op(h))
  end)
  assert_eq(failed_count, 1, 'failed settlement should not release ownership')
  assert_eq(rec.phase, 'live', 'the returned capability should restore the unresolved claim')
  assert_eq(rec.settlement_failed, nil)
end

print('tests/test_settlement_structure.lua: ok')
