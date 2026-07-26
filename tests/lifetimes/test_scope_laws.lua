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
local Lifetime = require('fibers.lifetime')
local Lifetimes = require('tests.support.lifetimes')
local FibersScope = require('fibers.scope')
local Closure = require('fibers.closure')

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
  local life = FibersScope.new('sealed-law')
  local h = Lifetimes.resource('sealed-law-owned')
  local result, owns
  fibers.run(function()
    fibers.perform(life:seal_op('test'))
    result = fibers.perform(life
      :admit_op(h)
      :map(function()
        return 'unexpected'
      end)
      :or_else(Op.always('sealed')))
    owns = fibers.perform(life:has_custody_op(h))
  end)
  assert_eq(result, 'sealed', 'sealed scope should reject admission')
  assert_eq(owns, false, 'rejected admission should leave item unowned')
end

-- Custody transfer is atomic and uses the public move_op calculus verb.
do
  local from = FibersScope.new('move-law-from')
  local to = FibersScope.new('move-law-to')
  local sealed = FibersScope.new('move-law-sealed')
  local h = Lifetimes.resource('move-law-owned')
  local moved, from_after, to_after, failed_move, still_to
  fibers.run(function()
    fibers.perform(from:admit_op(h))
    fibers.perform(from:move_op(h, to))
    moved = fibers.perform(to:has_custody_op(h))
    from_after = fibers.perform(from:has_custody_op(h))
    to_after = fibers.perform(to:has_custody_op(h))
    fibers.perform(sealed:seal_op('closed-target'))
    failed_move = fibers.perform(to:move_op(h, sealed)
      :map(function()
        return 'unexpected'
      end)
      :or_else(Op.always('blocked')))
    still_to = fibers.perform(to:has_custody_op(h))
    fibers.perform(Closure.close_op(to, h))
  end)
  assert_eq(moved, true, 'move_op should update concrete owner')
  assert_eq(from_after, false, 'source should not retain custody after move')
  assert_eq(to_after, true, 'target should receive custody after move')
  assert_eq(failed_move, 'blocked', 'move into sealed scope should not commit')
  assert_eq(still_to, true, 'failed move should leave custody unchanged')
end

-- Closure is the only public resolution path. Internal close tokens are not
-- exposed; successful closure retires custody and records a closed Lifetime.
do
  local life = FibersScope.new('closure-law')
  local h = Lifetimes.resource('closure-owned')
  local live_phase, owner_after, closure_phase
  fibers.run(function()
    fibers.perform(life:admit_op(h))
    live_phase = fibers.perform(life:custody_op(h)).phase
    fibers.perform(life:close_op(h, 'law closure'))
    local state = Lifetime.of(h):current_state()
    owner_after = state.custodian
    closure_phase = state.closure_phase
  end)
  assert_eq(live_phase, 'live', 'admission should establish live custody')
  assert_eq(owner_after, nil, 'closure should retire custody')
  assert_eq(closure_phase, 'closed', 'closure should record the terminal phase')
end

-- Closure protocols use the explicit request/finish contract.
-- Function finalisers are deliberately not accepted.
do
  local rejected = pcall(function()
    Lifetime.define({ name = 'function-protocol-rejected' }, {
      closure = function()
        return Op.always(true)
      end,
    })
  end)
  assert_eq(rejected, false, 'function Closure protocols should be rejected')
end

do
  local life = FibersScope.new('protocol-law')
  local discharged = false
  local h = Lifetimes.resource('protocol-law-owned', {
    name = 'table-protocol',
    finish_op = function()
      return Op.always(true):map(function()
        discharged = true
        return true
      end)
    end,
  })
  fibers.run(function()
    fibers.perform(life:admit_op(h))
    fibers.perform(Closure.close_op(life, h))
  end)
  assert_eq(discharged, true, 'protocol table finish_op should run during Closure')
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
  assert_eq(restored_after_ok, true, 'current scope should be restored after normal nested scope exit')
  assert_eq(restored_after_err, true, 'current scope should be restored after nested scope error')
end

print('tests/test_scope_laws.lua: ok')
