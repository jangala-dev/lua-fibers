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

-- Requests traverse parents before children. Settlement traverses children before
-- parents and reverses sibling declaration order.
do
  local life = FibersScope.new('ordered-settlement-life')
  local trace = {}
  local function protocol(name)
    return Settlement.protocol({
      name = name,
      request_op = function()
        return Op.always(true):map(function()
          trace[#trace + 1] = 'request ' .. name
          return true
        end)
      end,
      settle_op = function()
        return Op.always(true):map(function()
          trace[#trace + 1] = 'settle ' .. name
          return true
        end)
      end,
    })
  end
  local root = FibersRegion.handle('ordered-root')
  local a = FibersRegion.handle('ordered-a')
  local a1 = FibersRegion.handle('ordered-a1')
  local b = FibersRegion.handle('ordered-b')
  fibers.run(function()
    fibers.perform(life:admit_op(FibersRegion.Owned.tree(root, protocol('root'), {
      FibersRegion.Owned.tree(a, protocol('a'), {
        FibersRegion.Owned.item(a1, protocol('a1')),
      }),
      FibersRegion.Owned.item(b, protocol('b')),
    })))
    fibers.perform(Settlement.retire_item_op(life, root, 'ordered'))
  end)
  assert_eq(
    table.concat(trace, ', '),
    'request root, request a, request a1, request b, settle b, settle a1, settle a, settle root',
    'owned-tree settlement order'
  )
end

-- Parent settlement may depend on child settlement without deadlocking because
-- the settlement pass runs bottom-up.
do
  local life = FibersScope.new('dependent-settlement-life')
  local child_settled = false
  local parent = FibersRegion.handle('dependent-parent')
  local child = FibersRegion.handle('dependent-child')
  local parent_protocol = Settlement.protocol({
    name = 'dependent-parent',
    request_op = function()
      return Op.always(true)
    end,
    settle_op = function()
      if not child_settled then
        error('parent settled before child', 0)
      end
      return Op.always(true)
    end,
  })
  local child_protocol = Settlement.protocol({
    name = 'dependent-child',
    request_op = function()
      return Op.always(true)
    end,
    settle_op = function()
      return Op.always(true):map(function()
        child_settled = true
        return true
      end)
    end,
  })
  fibers.run(function()
    fibers.perform(life:admit_op(FibersRegion.Owned.tree(parent, parent_protocol, {
      FibersRegion.Owned.item(child, child_protocol),
    })))
    fibers.perform(Settlement.retire_item_op(life, parent, 'dependent'))
  end)
  assert_eq(child_settled, true)
end

-- Settlement is now a tree-level state transition.  The initiating request marks
-- the whole owned subtree as claimed before the masked settlement protocol
-- waits and then releases the subtree atomically.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('phase-life')
  local settled, feed = rt:signal('phase-settled')
  local K = Settlement.protocol({
    name = 'phase-test',
    settle_op = function()
      return settled:wait_op():map(function()
        return true
      end)
    end,
  })
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
    settle_without_claim = life:raw_region().resolve_op == nil and 'absent' or 'present'
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
  assert_eq(settle_without_claim, 'absent', 'Region should not expose generic claim resolution')
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

-- Failed settlement retains irreversible progress. Retry resumes from that
-- progress and never replays successful requests or settled sibling records.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('failing-settlement-life')
  local root = FibersRegion.handle('failing-root')
  local good = FibersRegion.handle('failing-good')
  local flaky = FibersRegion.handle('failing-flaky')
  local request_count = { root = 0, good = 0, flaky = 0 }
  local settle_count = { root = 0, good = 0, flaky = 0 }
  local flaky_attempt = 0

  local function protocol(name, settle)
    return Settlement.protocol({
      name = name,
      request_op = function()
        return Op.always(true):map(function()
          request_count[name] = request_count[name] + 1
          return true
        end)
      end,
      settle_op = settle or function()
        return Op.always(true):map(function()
          settle_count[name] = settle_count[name] + 1
          return true
        end)
      end,
    })
  end

  rt:spawn_raw(function()
    rt:perform(life:admit_op(FibersRegion.Owned.tree(root, protocol('root'), {
      FibersRegion.Owned.item(good, protocol('good')),
      FibersRegion.Owned.item(
        flaky,
        protocol('flaky', function()
          flaky_attempt = flaky_attempt + 1
          settle_count.flaky = settle_count.flaky + 1
          if flaky_attempt == 1 then
            error('settlement boom', 0)
          end
          return Op.always(true)
        end)
      ),
    })))
    rt:perform(Settlement.retire_item_op(life, root, 'retire'))
  end, 'failing-settlement-root')

  local ok, failure = pcall(function()
    return rt:run()
  end)
  assert_eq(ok, false, 'settlement protocol failure should fail the waiting task')
  assert_truthy(Settlement.is_failure(failure), 'settlement error should be a recovery capability')
  assert_truthy(tostring(failure):match('settlement boom'), 'settlement error should be propagated')
  assert_eq(failure.retry_op ~= nil, true, 'failed settlement should expose retry authority')
  assert_eq(failure.restore_op, nil, 'started settlement must not expose generic restoration')
  local can_discharge_incomplete = pcall(function()
    failure.region:_discharge_settled_claim_op(failure.claim)
  end)
  assert_eq(
    can_discharge_incomplete,
    false,
    'an incomplete settlement claim must not be erased through the low-level Region API'
  )

  local records = {}
  fibers.run(function()
    records.root = fibers.perform(life:record_op(root))
    records.good = fibers.perform(life:record_op(good))
    records.flaky = fibers.perform(life:record_op(flaky))
  end)
  assert_eq(records.root.phase, 'failed')
  assert_eq(records.root.settlement_state, 'blocked_by_descendant')
  assert_eq(records.good.settlement_state, 'settled')
  assert_eq(records.good.settlement_failed, false)
  assert_eq(records.flaky.settlement_state, 'settlement_failed')
  assert_eq(request_count.root, 1)
  assert_eq(request_count.good, 1)
  assert_eq(request_count.flaky, 1)
  assert_eq(settle_count.root, 0, 'unresolved child must block parent settlement')
  assert_eq(settle_count.good, 1)
  assert_eq(settle_count.flaky, 1)

  fibers.run(function()
    fibers.perform(failure:retry_op())
  end)
  assert_eq(request_count.root, 1, 'successful request must not replay during retry')
  assert_eq(request_count.good, 1, 'settled sibling request must not replay during retry')
  assert_eq(request_count.flaky, 1, 'successful flaky request must not replay during retry')
  assert_eq(settle_count.good, 1, 'settled sibling must not settle twice')
  assert_eq(settle_count.flaky, 2, 'failed record should retry settlement')
  assert_eq(settle_count.root, 1, 'parent should settle after all children')
  assert_eq(root.owner, nil, 'successful retry should discharge the complete tree')
end

-- Retrying a failed claim resumes its public phase to claimed before
-- protocol work, preserving ordinary settlement authority checks.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('retry-authority-life')
  local item = FibersRegion.handle('retry-authority-item')
  local attempts = 0
  local observed_phases = {}
  local protocol = Settlement.protocol({
    name = 'retry-authority',
    settle_op = function(ctx, record)
      return ctx:authorise_op(record.item, 'use')
    end,
    settle_result = function(authorised_item, authority)
      attempts = attempts + 1
      observed_phases[#observed_phases + 1] = authority and authority.kind or nil
      if authorised_item ~= item or not authority then
        error('settlement authority unavailable during retry', 0)
      end
      if attempts == 1 then
        error('retry authority test', 0)
      end
      return true
    end,
  })
  rt:spawn_raw(function()
    rt:perform(life:admit_op(FibersRegion.Owned.item(item, protocol)))
    rt:perform(Settlement.retire_item_op(life, item, 'retry-authority'))
  end, 'retry-authority-root')

  local ok, failure = pcall(function()
    return rt:run()
  end)
  assert_eq(ok, false)
  assert_truthy(Settlement.is_failure(failure))
  fibers.run(function()
    fibers.perform(failure:retry_op())
  end)
  assert_eq(attempts, 2)
  assert_eq(observed_phases[1], 'settlement')
  assert_eq(observed_phases[2], 'settlement')
  assert_eq(item.owner, nil)
  local stale_retry = pcall(function()
    failure:retry_op()
  end)
  assert_eq(stale_retry, false, 'completed recovery capability should not be reusable')
end

-- Force escalation runs top-down, then observes final settlement bottom-up.
do
  local rt = FibersRuntime.new()
  local life = FibersScope.new('force-settlement-life')
  local root = FibersRegion.handle('force-root')
  local a = FibersRegion.handle('force-a')
  local b = FibersRegion.handle('force-b')
  local trace = {}
  local function protocol(name)
    return Settlement.protocol({
      name = name,
      request_op = function()
        error('ordinary request failed for ' .. name, 0)
      end,
      force_op = function()
        return Op.always(true):map(function()
          trace[#trace + 1] = 'force ' .. name
          return true
        end)
      end,
      settle_op = function()
        return Op.always(true):map(function()
          trace[#trace + 1] = 'settle ' .. name
          return true
        end)
      end,
    })
  end
  local failure
  rt:spawn_raw(function()
    rt:perform(life:admit_op(FibersRegion.Owned.tree(root, protocol('root'), {
      FibersRegion.Owned.item(a, protocol('a')),
      FibersRegion.Owned.item(b, protocol('b')),
    })))
    rt:perform(Settlement.retire_item_op(life, root, 'force'))
  end, 'force-settlement-root')
  local ok, err = pcall(function()
    return rt:run()
  end)
  assert_eq(ok, false)
  failure = err
  assert_truthy(Settlement.is_failure(failure))
  fibers.run(function()
    fibers.perform(failure:force_op())
  end)
  assert_eq(
    table.concat(trace, ', '),
    'force root, force a, force b, settle b, settle a, settle root',
    'force and settlement ordering'
  )
end

-- Independent roots unwind in reverse admission order. Their internal trees
-- retain the separate top-down request and bottom-up settlement law.
do
  local trace = {}
  local function root(name)
    return FibersRegion.handle('root-order-' .. name, {
      settle = Settlement.protocol({
        name = 'root-order-' .. name,
        settle_op = function()
          return Op.always(true):map(function()
            trace[#trace + 1] = name
            return true
          end)
        end,
      }),
      settle_name = 'root-order-' .. name,
    })
  end
  local a, b, c = root('a'), root('b'), root('c')
  fibers.run(function()
    fibers.scope(function(scope)
      fibers.perform(scope:admit_op(a))
      fibers.perform(scope:admit_op(b))
      fibers.perform(scope:admit_op(c))
    end)
  end)
  assert_eq(table.concat(trace, ', '), 'c, b, a', 'independent roots should unwind as a stack')
end

print('tests/test_settlement_structure.lua: ok')
