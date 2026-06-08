package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- Region is a generic ownership boundary: it can admit, transfer and settle a
-- non-task handle, and ownership transitions publish lifetime effects.
do
  local a = fibers.Region.new('A')
  local b = fibers.Region.new('B')
  local item = fibers.Region.handle('lease', { kind = 'lease' })
  local admitted, transferred, settled

  local st = fibers.run(function()
    admitted = fibers.perform(a:admit_op(item))
    transferred = fibers.perform(a:transfer_op(item, b))
    settled = fibers.perform(b:settle_op(item))
  end)

  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(transferred, item)
  assert_eq(settled, item)
  assert_eq(item.owner, nil)
  assert_eq(a.owned[item], nil)
  assert_eq(b.owned[item], nil)

  -- Runtime returned by fibers.run is second result.
end

-- Transfer is one operation, not release-then-admit exposed as two public
-- transitions.  The ownership effect should be transferred.
do
  local a = fibers.Region.new('A2')
  local b = fibers.Region.new('B2')
  local item = fibers.Region.handle('subscription', { kind = 'subscription' })
  local rt

  local st
  st, rt = fibers.run(function()
    fibers.perform(a:admit_op(item))
    fibers.perform(a:transfer_op(item, b))
  end)

  assert_status(st, 'found')
  assert_eq(item.owner, b)
  local saw_transfer = false
  local saw_release_admit_pair = false
  local events = rt.published_lifetime or {}
  for i = 1, #events do
    if events[i].type == 'transferred' and events[i].item == item and events[i].from == a and events[i].to == b then
      saw_transfer = true
    end
  end
  -- There will also be an admitted event for the initial admission, but the
  -- transfer itself should not appear as item settled from A and admitted to B.
  for i = 1, #events do
    if events[i].type == 'settled' and events[i].item == item and events[i].from == a then
      saw_release_admit_pair = true
    end
  end
  assert_truthy(saw_transfer, 'transfer should publish transferred lifetime event')
  assert_eq(saw_release_admit_pair, false, 'transfer should not publish settled event from source')
end

-- Sealing is admission policy only: it blocks new admissions and incoming
-- transfers, but does not settle or cancel already-owned items.
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

  -- Cannot admit to or transfer into a sealed target.
  local item2 = fibers.Region.handle('late')
  local st2 = fibers.run(function()
    fibers.perform(a:admit_op(item2))
  end)
  assert_status(st2, 'absent')

  local st3 = fibers.run(function()
    fibers.perform(a:transfer_op(item, b))
    fibers.perform(b:seal_op())
  end)
  -- Both operations can commit in sequence inside one fibre: transfer first,
  -- then seal.  Check the target is still the owner afterwards.
  assert_status(st3, 'found')
  assert_eq(item.owner, b)
end

-- Task-specific spawning now belongs to Task; Region merely admits ownership.
do
  local region = fibers.Region.new('task-region')
  local task, status, value
  local st = fibers.run(function()
    task = fibers.perform(fibers.Task.spawn_op(region, function() return 99 end, 'child'))
    status, value = fibers.perform(task:join_op())
  end)
  assert_status(st, 'found')
  assert_eq(task.owner, region)
  assert_eq(status, 'ok')
  assert_eq(value, 99)
end

-- A Task cannot be settled while still running; once it completes, its owning
-- Region may settle it like any other owned handle.
do
  local region = fibers.Region.new('settle-task-region')
  local task
  local st = fibers.run(function()
    task = fibers.perform(fibers.Task.spawn_op(region, function() return 'done' end, 'settle-child'))
    fibers.perform(task:join_op())
    fibers.perform(region:settle_op(task))
  end)
  assert_status(st, 'found')
  assert_eq(task.owner, nil)
  assert_eq(region.owned[task], nil)
end

print('tests/test_region_general.lua: ok')
