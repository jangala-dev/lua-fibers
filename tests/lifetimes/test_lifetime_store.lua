package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Lifetime = require('fibers.lifetime')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local Closure = require('fibers.closure')

local function eq(a, b, msg)
  if a ~= b then
    error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end
local function truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

local function resource(name, children)
  local value = { name = name }
  Lifetime.inert(value, { name = name, children = children })
  return value
end

-- The lifetime forest is demand-driven. Closed algebraic work does not pay for
-- it; the first lifetime operation creates one store which is then retained.
do
  local runtime = Runtime.new()
  eq(runtime.lifetimes, nil, 'bare Runtime must not allocate a LifetimeStore')
  local item = resource('lazy-store')
  Lifetime.of(item):bind_runtime(runtime)
  local store = runtime.lifetimes
  truthy(store, 'binding a Lifetime creates the Runtime-local store')
  eq(runtime:_lifetime_store(), store, 'the Runtime reuses its LifetimeStore')
end

-- A dormant Lifetime becomes live only through committed admission and the
-- Runtime-local store is the sole owner of its topology.
do
  local item = resource('store-item')
  local before = Lifetime.of(item)
  eq(before:current_state().closure_phase, 'dormant')
  fibers.run(function(scope)
    eq(fibers.perform(scope:has_custody_op(item)), false)
    eq(fibers.perform(scope:admit_op(item)), item)
    eq(before:current_state().closure_phase, 'open')
    eq(before:current_state().custodian, scope:lifetime())
    truthy(fibers.perform(scope:has_custody_op(item)))
  end)
  eq(before:current_state().closure_phase, 'closed')
  eq(before:current_state().custodian, nil)
end

-- Lifetime definitions are one-shot and structural children must be explicit.
do
  local value = resource('one-shot-definition')
  local ok, err = pcall(function()
    Lifetime.define(value, { role = 'redefined' })
  end)
  eq(ok, false)
  truthy(tostring(err):match('already carries a Lifetime'))

  local parent = resource('explicit-parent')
  ok, err = pcall(function()
    Lifetime.of(parent):add_child({ name = 'implicit-child' })
  end)
  eq(ok, false)
  truthy(tostring(err):match('Lifetime.inert explicitly'))

  local child = resource('explicit-child')
  Lifetime.of(parent):add_child(child)
  eq(Lifetime.of(child):current_state().parent, Lifetime.of(parent))
end

-- Dormant structural topology is a tree. Ordinary construction rejects an
-- ancestor edge, and binding independently validates malformed raw graphs
-- before recursion can overflow or partial admission can occur.
do
  local a, b = resource('cycle-a'), resource('cycle-b')
  Lifetime.of(a):add_child(b)
  local ok, err = pcall(function()
    Lifetime.of(b):add_child(a)
  end)
  eq(ok, false)
  truthy(tostring(err):match('acyclic tree'))

  local c, d = resource('raw-cycle-c'), resource('raw-cycle-d')
  Lifetime.of(c):add_child(d)
  Lifetime.of(d)._construction_children[1] = Lifetime.of(c)
  Lifetime.of(c)._construction_parent = Lifetime.of(d)
  ok, err = pcall(function()
    Lifetime.of(c):bind_runtime(Runtime.new())
  end)
  eq(ok, false)
  truthy(tostring(err):match('acyclic tree'))
  eq(Lifetime.of(c).runtime, nil, 'failed validation must not partially bind the root')
  eq(Lifetime.of(d).runtime, nil, 'failed validation must not partially bind descendants')
end

-- Ordinary Lua fields are not authoritative topology. Trusted code may add
-- fields to a Lifetime handle without changing the store-backed custody forest.
do
  local item = resource('store-only-topology')
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(item))
    local node = Lifetime.of(item)
    node.parent, node.children, node.phase = 'user-data', {}, 'user-data'
    local state = node:current_state()
    eq(state.custodian, scope:lifetime())
    eq(state.parent, nil)
    eq(state.closure_phase, 'open')
  end)
end

-- Closure has one explicit monotonic state machine shared by cancellation and
-- Closure.
do
  local item = resource('closure-phases')
  local node = Lifetime.of(item)
  local requested, closing
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(item))
    fibers.perform(node:request_close_op('test-close'))
    requested = node:current_state().closure_phase
    fibers.perform(node:_closing_op('test-close'))
    closing = node:current_state().closure_phase
  end)
  eq(requested, 'close_requested')
  eq(closing, 'closing')
  eq(node:current_state().closure_phase, 'closed')
end

-- A complete subtree moves atomically between Scope capabilities.
do
  local leaf = resource('move-leaf')
  local root = resource('move-root', { leaf })
  local seen_inner, seen_outer
  fibers.run(function(outer)
    fibers.scope(function(inner)
      fibers.perform(inner:admit_op(root))
      truthy(fibers.perform(inner:has_custody_op(root)))
      truthy(fibers.perform(inner:has_custody_op(leaf)))
      fibers.perform(inner:move_op(root, outer))
      seen_inner = fibers.perform(inner:has_custody_op(root))
      seen_outer = fibers.perform(outer:has_custody_op(root))
      truthy(fibers.perform(outer:has_custody_op(leaf)))
    end)
  end)
  eq(seen_inner, false)
  eq(seen_outer, true)
end

-- Constructing a running Lifetime is inert; its body starts only when the
-- admission operation commits.
do
  local started = false
  fibers.run(function(scope)
    local op = scope:spawn_op(function()
      started = true
      return 'ok'
    end, 'inert-start')
    eq(started, false)
    local task = fibers.perform(op)
    eq(fibers.perform(task:await_op()), 'ok')
  end)
  eq(started, true)
end

-- Stores are Runtime-local. A live node cannot cross runtimes, and destroying
-- one Runtime does not affect another.
do
  local rt1, rt2 = Runtime.new(), Runtime.new()
  local s1 = Scope.new('runtime-one', { runtime = rt1, closure = Closure.nursery() })
  local s2 = Scope.new('runtime-two', { runtime = rt2, closure = Closure.nursery() })
  local item = resource('runtime-local')
  local admitted
  rt1:spawn_raw(function()
    admitted = rt1:perform(s1:admit_op(item))
  end, 'admit-one', s1)
  rt1:run()
  eq(admitted, item)
  local ok, err = pcall(function()
    item._lifetime:bind_runtime(rt2)
  end)
  eq(ok, false)
  truthy(tostring(err):match('another Runtime'))
  eq(s2._lifetime.runtime, rt2)
end

print('tests/lifetimes/test_lifetime_store.lua: ok')
