package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- Region is a generic ownership boundary: it can admit, reassign and release a
-- non-task handle, and ownership transitions discharge lifetime effects.
do
  local a = fibers.Region.new('A')
  local b = fibers.Region.new('B')
  local item = fibers.Region.handle('lease', { kind = 'lease' })
  local admitted, reassigned, released

  local st = fibers.run(function()
    admitted = fibers.perform(a:admit_op(item))
    reassigned = fibers.perform(a:reassign_op(item, b))
    released = fibers.perform(b:release_op(item))
  end)

  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(reassigned, item)
  assert_eq(released, item)
  assert_eq(item.owner, nil)
  assert_eq(a.owned[item], nil)
  assert_eq(b.owned[item], nil)

  -- Runtime returned by fibers.run is second result.
end

-- Reassignment is one ledger command, not release-then-admit exposed as two public
-- transitions.  The ownership effect should be reassigned.
do
  local a = fibers.Region.new('A2')
  local b = fibers.Region.new('B2')
  local item = fibers.Region.handle('subscription', { kind = 'subscription' })
  local events = {}
  local st
  st = fibers.run(function()
    fibers.perform(a:admit_op(item))
    fibers.perform(a:reassign_op(item, b))
  end, { host = { lifetime = function(e) events[#events + 1] = e end } })

  assert_status(st, 'found')
  assert_eq(item.owner, b)
  local saw_reassign = false
  local saw_release_admit_pair = false
  for i = 1, #events do
    if events[i].type == 'reassigned' and events[i].item == item and events[i].from == a and events[i].to == b then
      saw_reassign = true
    end
  end
  -- There will also be an admitted event for the initial admission, but the
  -- reassignment itself should not appear as item released from A and admitted to B.
  for i = 1, #events do
    if events[i].type == 'released' and events[i].item == item and events[i].from == a then
      saw_release_admit_pair = true
    end
  end
  assert_truthy(saw_reassign, 'reassignment should discharge reassigned region event')
  assert_eq(saw_release_admit_pair, false, 'reassignment should not discharge released event from source region')
end

-- Sealing is admission policy only: it blocks new admissions and incoming
-- reassignments, but does not release or cancel already-owned items.
do
  local a = fibers.Region.new('sealed-A')
  local b = fibers.Region.new('sealed-B')
  local item = fibers.Region.handle('handle')
  local ok_open, ok_sealed, owns

  local st = fibers.run(function()
    fibers.perform(a:admit_op(item))
    ok_open = fibers.perform(a:is_open_op())
    fibers.perform(a:seal_op())
    ok_sealed = fibers.perform(a:is_open_op())
    owns = fibers.perform(a:owns_op(item))
  end)

  assert_status(st, 'found')
  assert_eq(ok_open, true)
  assert_eq(ok_sealed, false)
  assert_eq(owns, true)
  assert_eq(item.owner, a)

  -- Cannot admit to or reassign into a sealed target.
  local item2 = fibers.Region.handle('late')
  local st2 = fibers.run(function()
    fibers.perform(a:admit_op(item2))
  end)
  assert_status(st2, 'absent')

  local st3 = fibers.run(function()
    fibers.perform(a:reassign_op(item, b))
    fibers.perform(b:seal_op())
  end)
  -- Both options can commit in sequence inside one fibre: reassign first,
  -- then seal.  Check the target is still the owner afterwards.
  assert_status(st3, 'found')
  assert_eq(item.owner, b)
end

-- Task-specific spawning now belongs to Task; Region merely admits ownership.
do
  local region = fibers.Region.new('task-region')
  local task, value
  local st = fibers.run(function()
    task = fibers.perform(fibers.Task.spawn_op(region, function() return 99 end, 'child'))
    value = fibers.perform(task:await_op())
  end)
  assert_status(st, 'found')
  assert_eq(task.owner, region)
  assert_eq(value, 99)
end

-- A Task cannot be released while still running; once it completes, its owning
-- Region may release it like any other owned handle.
do
  local region = fibers.Region.new('settle-task-region')
  local task
  local st = fibers.run(function()
    task = fibers.perform(fibers.Task.spawn_op(region, function() return 'done' end, 'settle-child'))
    fibers.perform(task:await_op())
    fibers.perform(region:release_op(task))
  end)
  assert_status(st, 'found')
  assert_eq(task.owner, nil)
  assert_eq(region.owned[task], nil)
end


-- Region exposes committed ownership as a fact; policy need not shadow it.
do
  local region = fibers.Region.new('owned-observation-region')
  local a = fibers.Region.handle('a')
  local b = fibers.Region.handle('b')
  local owned_before, owned_after
  local st = fibers.run(function()
    fibers.perform(region:admit_op(a))
    fibers.perform(region:admit_op(b))
    owned_before = fibers.perform(region:members_op())
    fibers.perform(region:release_op(a))
    owned_after = fibers.perform(region:members_op())
  end)
  assert_status(st, 'found')
  assert_eq(#owned_before, 2)
  assert_eq(#owned_after, 1)
  assert_eq(owned_after[1], b)
end


-- A claim is a capability object, not just a visible claim id.  Public record
-- projections may reveal diagnostic claim metadata, but must not expose the
-- authority object, and a forged table with the same id must not settle it.
do
  local region = fibers.Region.new('claim-authority-region')
  local parent = fibers.Region.handle('claim-parent')
  local child = fibers.Region.handle('claim-child')
  local claim, rec, subtree, forged_result, settled

  local st = fibers.run(function()
    fibers.perform(region:admit_op(fibers.Region.Owned.tree(parent, nil, {
      fibers.Region.Owned.inert(child),
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

    forged_result = fibers.perform(fibers.choice(
      region:settle_claim_op(fake):map(function() return 'forged-settled' end),
      fibers.always('blocked')
    ))
    settled = fibers.perform(region:settle_claim_op(claim))
  end)

  assert_status(st, 'found')
  assert_truthy(claim and claim._fibers_claim, 'real claim should be produced')
  assert_eq(rec.claim, nil, 'record_op must not expose claim authority')
  assert_eq(subtree[1].claim, nil, 'subtree_op must not expose claim authority')
  assert_eq(rec.claim_id, claim.id, 'public record may expose diagnostic claim id')
  assert_eq(forged_result, 'blocked', 'forged claim with matching id must be rejected')
  assert_eq(settled, parent, 'real claim should settle')
  assert_eq(parent.owner, nil)
  assert_eq(child.owner, nil)
end

print('tests/test_region_general.lua: ok')
