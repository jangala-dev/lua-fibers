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
local FibersRegion = require('fibers.region')
local FibersTask = require('fibers.task')
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

-- Region is a generic ownership boundary: it can admit, move and release a
-- non-task handle, and ownership transitions discharge scope effects.
do
  local a = FibersRegion.new('A')
  local b = FibersRegion.new('B')
  local item = FibersRegion.handle('lease', { kind = 'lease' })
  local admitted, moved, released

  local st = fibers.try_run(function()
    admitted = fibers.perform(a:admit_op(item))
    moved = fibers.perform(a:move_op(item, b))
    released = fibers.perform(b:release_op(item))
  end).runtime_status

  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(moved, item)
  assert_eq(released, item)
  assert_eq(item.owner, nil)
  assert_eq(a.owned[item], nil)
  assert_eq(b.owned[item], nil)

  -- Runtime returned by fibers.run is second result.
end

-- Movement is one ledger command, not release-then-admit exposed as two public
-- transitions.  The ownership effect should be moved.
do
  local a = FibersRegion.new('A2')
  local b = FibersRegion.new('B2')
  local item = FibersRegion.handle('subscription', { kind = 'subscription' })
  local events = {}
  local st
  st = fibers.try_run(function()
    fibers.perform(a:admit_op(item))
    fibers.perform(a:move_op(item, b))
  end, { host = {
    scope = function(e)
      events[#events + 1] = e
    end,
  } }).runtime_status

  assert_status(st, 'found')
  assert_eq(item.owner, b)
  local saw_move = false
  local saw_release_admit_pair = false
  for i = 1, #events do
    if events[i].type == 'moved' and events[i].item == item and events[i].from == a and events[i].to == b then
      saw_move = true
    end
  end
  -- There will also be an admitted event for the initial admission, but the
  -- movement itself should not appear as item released from A and admitted to B.
  for i = 1, #events do
    if events[i].type == 'released' and events[i].item == item and events[i].from == a then
      saw_release_admit_pair = true
    end
  end
  assert_truthy(saw_move, 'movement should discharge moved region event')
  assert_eq(saw_release_admit_pair, false, 'movement should not discharge released event from source region')
end

-- Sealing is admission policy only: it blocks new admissions and incoming
-- moves, but does not release or cancel already-owned items.
do
  local a = FibersRegion.new('sealed-A')
  local b = FibersRegion.new('sealed-B')
  local item = FibersRegion.handle('handle')
  local ok_open, ok_sealed, owns

  local st = fibers.try_run(function()
    fibers.perform(a:admit_op(item))
    ok_open = fibers.perform(a:is_open_op())
    fibers.perform(a:seal_op())
    ok_sealed = fibers.perform(a:is_open_op())
    owns = fibers.perform(a:owns_op(item))
  end).runtime_status

  assert_status(st, 'found')
  assert_eq(ok_open, true)
  assert_eq(ok_sealed, false)
  assert_eq(owns, true)
  assert_eq(item.owner, a)

  -- Cannot admit to or move into a sealed target.
  local item2 = FibersRegion.handle('late')
  local st2 = fibers.try_run(function()
    fibers.perform(a:admit_op(item2))
  end).runtime_status
  assert_status(st2, 'quiescent')

  local st3 = fibers.try_run(function()
    fibers.perform(a:move_op(item, b))
    fibers.perform(b:seal_op())
  end).runtime_status
  -- Both options can commit in sequence inside one fibre: move first,
  -- then seal.  Check the target is still the owner afterwards.
  assert_status(st3, 'found')
  assert_eq(item.owner, b)
end

-- Task-specific spawning now belongs to Task; Region merely admits ownership.
do
  local region = FibersRegion.new('task-region')
  local task, value
  local st = fibers.try_run(function()
    task = fibers.perform(FibersTask.spawn_op(region, function()
      return 99
    end, 'child'))
    value = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(task.owner, region)
  assert_eq(value, 99)
end

-- A Task cannot be released while still running; once it completes, its owning
-- Region may release it like any other owned handle.
do
  local region = FibersRegion.new('settle-task-region')
  local task
  local st = fibers.try_run(function()
    task = fibers.perform(FibersTask.spawn_op(region, function()
      return 'done'
    end, 'settle-child'))
    fibers.perform(task:await_op())
    fibers.perform(region:release_op(task))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(task.owner, nil)
  assert_eq(region.owned[task], nil)
end

-- Region exposes committed ownership as a fact; policy need not shadow it.
do
  local region = FibersRegion.new('owned-observation-region')
  local a = FibersRegion.handle('a')
  local b = FibersRegion.handle('b')
  local owned_before, owned_after
  local st = fibers.try_run(function()
    fibers.perform(region:admit_op(a))
    fibers.perform(region:admit_op(b))
    owned_before = fibers.perform(region:members_op())
    fibers.perform(region:release_op(a))
    owned_after = fibers.perform(region:members_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(#owned_before, 2)
  assert_eq(#owned_after, 1)
  assert_eq(owned_after[1], b)
end

-- A claim is a capability object, not just a visible claim id.  Public record
-- projections may reveal diagnostic claim metadata, but must not expose the
-- authority object, and a forged table with the same id must not settle it.
do
  local region = FibersRegion.new('claim-authority-region')
  local parent = FibersRegion.handle('claim-parent')
  local child = FibersRegion.handle('claim-child')
  local claim, rec, subtree, forged_result, settled

  local st = fibers.try_run(function()
    fibers.perform(region:admit_op(FibersRegion.Owned.tree(parent, nil, {
      FibersRegion.Owned.inert(child),
    })))
    claim = fibers.perform(region:claim_op(parent, { type = 'test', reason = 'capability' }))
    rec = fibers.perform(region:record_op(parent))
    subtree = fibers.perform(region:subtree_op(parent))

    local fake = {
      _fibers_claim = true,
      _fibers_value = true,
      id = claim.id,
      region = region,
      root = parent,
      records = claim.records,
      purpose = claim.purpose,
      reason = claim.reason,
    }

    forged_result = fibers.perform(region
      :_restore_pristine_claim_op(fake)
      :map(function()
        return 'forged-restored'
      end)
      :or_else(Op.always('blocked')))
    fibers.perform(claim:restore_op())
    settled = fibers.perform(Settlement.retire_item_op(region, parent, 'capability test'))
  end).runtime_status

  assert_status(st, 'found')
  assert_truthy(claim and claim._fibers_claim, 'real claim should be produced')
  assert_eq(rec.claim, nil, 'record_op must not expose claim authority')
  assert_eq(subtree[1].claim, nil, 'subtree_op must not expose claim authority')
  assert_eq(rec.claim_id, claim.id, 'public record may expose diagnostic claim id')
  assert_eq(forged_result, 'blocked', 'forged claim with matching id must be rejected')
  assert_eq(settled, parent, 'settlement should retire the real tree')
  assert_eq(parent.owner, nil)
  assert_eq(child.owner, nil)
end

print('tests/test_region_general.lua: ok')
