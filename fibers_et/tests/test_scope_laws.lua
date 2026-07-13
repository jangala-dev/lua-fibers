package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Settlement = require('fibers.internal.settlement')

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

-- A sealed scope accepts no new custody.
do
  local life = fibers.Scope.new('sealed-law')
  local h = fibers.Region.handle('sealed-law-owned')
  local result, owns
  fibers.run(function()
    fibers.perform(life:seal_op('test'))
    result = fibers.perform(life
      :admit_op(h)
      :map(function()
        return 'unexpected'
      end)
      :or_else(fibers.always('sealed')))
    owns = fibers.perform(life:owns_op(h))
  end)
  assert_eq(result, 'sealed', 'sealed scope should reject admission')
  assert_eq(owns, false, 'rejected admission should leave item unowned')
end

-- Custody transfer is atomic and uses the public move_op calculus verb.
do
  local from = fibers.Scope.new('move-law-from')
  local to = fibers.Scope.new('move-law-to')
  local sealed = fibers.Scope.new('move-law-sealed')
  local h = fibers.Region.handle('move-law-owned')
  local moved, from_after, to_after, failed_move, still_to
  fibers.run(function()
    fibers.perform(from:admit_op(h))
    fibers.perform(from:move_op(h, to))
    moved = h.owner == to:raw_region()
    from_after = fibers.perform(from:owns_op(h))
    to_after = fibers.perform(to:owns_op(h))
    fibers.perform(sealed:seal_op('closed-target'))
    failed_move = fibers.perform(to:move_op(h, sealed)
      :map(function()
        return 'unexpected'
      end)
      :or_else(fibers.always('blocked')))
    still_to = fibers.perform(to:owns_op(h))
    fibers.perform(Settlement.retire_item_op(to, h))
  end)
  assert_eq(moved, true, 'move_op should update concrete owner')
  assert_eq(from_after, false, 'source should not retain custody after move')
  assert_eq(to_after, true, 'target should receive custody after move')
  assert_eq(failed_move, 'blocked', 'move into sealed scope should not commit')
  assert_eq(still_to, true, 'failed move should leave custody unchanged')
end

-- Scope claim and resolve are dual public operations over the Region lifecycle.
do
  local life = fibers.Scope.new('claim-resolve-law')
  local h = fibers.Region.handle('claim-resolve-owned')
  local claimed_phase, restored_phase, owner_after
  fibers.run(function()
    fibers.perform(life:admit_op(h))
    local claim = fibers.perform(life:claim_op(h, { type = 'law', reason = 'restore' }))
    claimed_phase = fibers.perform(life:record_op(h)).phase
    fibers.perform(life:resolve_op(claim, { kind = 'restore' }))
    restored_phase = fibers.perform(life:record_op(h)).phase
    local final = fibers.perform(life:claim_op(h, { type = 'law', reason = 'discharge' }))
    fibers.perform(life:resolve_op(final, { kind = 'discharge' }))
    owner_after = h.owner
  end)
  assert_eq(claimed_phase, 'claimed', 'claim_op should claim the record')
  assert_eq(restored_phase, 'live', 'resolve restore should make the record live')
  assert_eq(owner_after, nil, 'resolve discharge should release owner')
end

-- Settlement protocol tables are normalised and remain backwards-compatible
-- with existing function protocols.
do
  local life = fibers.Scope.new('protocol-law')
  local h = fibers.Region.handle('protocol-law-owned')
  local discharged = false
  fibers.run(function()
    fibers.perform(life:admit_op(fibers.Region.Owned.item(h, {
      name = 'table-protocol',
      discharge_op = function()
        return fibers.always(true):map(function()
          discharged = true
          return true
        end)
      end,
    })))
    fibers.perform(Settlement.retire_item_op(life, h))
  end)
  assert_eq(discharged, true, 'protocol table discharge_op should run during settlement')
end

-- Ambient scope usage is restored after nested scopes and errors.
do
  local root_seen, inner_seen, restored_after_ok, restored_after_err
  local spawn_outside_ok, spawn_outside_err
  spawn_outside_ok, spawn_outside_err = pcall(function()
    fibers.spawn(function() end)
  end)
  fibers.run(function(root)
    root_seen = fibers.current_scope() == root
    fibers.scope(function(inner)
      inner_seen = fibers.current_scope() == inner
    end)
    restored_after_ok = fibers.current_scope() == root
    fibers.pcall(function()
      fibers.scope(function()
        error('inner boom')
      end)
    end)
    restored_after_err = fibers.current_scope() == root
  end)
  assert_eq(spawn_outside_ok, false, 'fibers.spawn outside a scope should fail')
  assert_truthy(
    tostring(spawn_outside_err):match('current scope'),
    'spawn error should mention current scope'
  )
  assert_eq(root_seen, true, 'fibers.run should install root current scope')
  assert_eq(inner_seen, true, 'fibers.scope should install nested current scope')
  assert_eq(
    restored_after_ok,
    true,
    'current scope should be restored after normal nested scope exit'
  )
  assert_eq(restored_after_err, true, 'current scope should be restored after nested scope error')
end

print('tests/test_scope_laws.lua: ok')
