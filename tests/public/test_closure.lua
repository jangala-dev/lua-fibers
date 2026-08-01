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
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersSignal = require('fibers.resource.signal')
local FibersClosure = require('fibers.closure')
local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Closure = FibersClosure

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

-- The friendly spawn name uses the current root scope installed by fibers.run.
do
  local child
  local st = fibers.try_run(function()
    child = fibers.spawn(function()
      return 'ok'
    end)
    local exit = fibers.perform(child:body_result_op())
    assert_eq(exit.tag, 'returned')
  end).runtime_status
  assert_truthy(
    st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle',
    'unexpected status: ' .. tostring(st.tag)
  )
  assert_truthy(child, 'fibers.spawn should return a task handle under the root scope')
end

-- A custom nursery Closure is passed to run/try_run; it is not a separate
-- launch path.
do
  local got, child
  local r = fibers.try_run(function(scope)
    local ch = FibersRendezvous.new('closure-rendezvous')
    child = fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:get_op())
    assert_truthy(scope:lifetime(), 'root Scope should expose its Lifetime to compound authors')
  end, { closure = FibersClosure.nursery() })
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(got, 'hello')
  assert_truthy(child, 'nursery spawn should return a task handle')
end

-- Direct cancellation is task-level. Scope Closure uses the same task/resource
-- protocols internally during closure.
do
  local task
  local r = fibers.try_run(function()
    local src = FibersSignal.new('closure-cancel-source')
    task = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'waiter')
    fibers.perform(task:request_cancel_op('stop'))
    local exit = fibers.perform(task:body_result_op())
    assert_truthy(
      exit.tag == 'cancelled' or exit.tag == 'failed',
      'explicit cancellation should end the task'
    )
  end, { closure = FibersClosure.nursery() })
  assert_truthy(r.ok, tostring(r.report or r.reason))
end

-- Body failure cancels owned children before the nursery reports the body error.
do
  local child
  local r = fibers.try_run(function()
    local src = FibersSignal.new('closure-body-failure-source')
    child = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'owned-waiter')
    error('body failed')
  end, { closure = FibersClosure.nursery() })
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'body_error')
  assert_truthy(tostring(r.primary):match('body failed'))

  local state
  local st = fibers.try_run(function()
    state = fibers.perform(child:state_op())
  end).runtime_status
  assert_status(st, 'found', 'status after inspecting cancelled child')
  assert_truthy(
    state.body_result.tag == 'cancelled' or state.body_result.tag == 'failed',
    'child should be cancelled or report scope failure under body failure'
  )
end

-- A custom Closure supplies pure propagation decisions while the Lifetime
-- driver retains local shutdown and result accounting.
do
  local entered = false
  local closure = {
    name = 'custom-boundary',
    permit_unstructured = false,
    permit_outward_move = true,
    permit_admission = true,
    on_body_result = function(_self, parent, _state, ok)
      entered = parent ~= nil and ok == true
      return { seal = true }
    end,
  }
  local r = fibers.try_run(function()
    return 'custom-ok'
  end, { closure = FibersClosure.running(closure) })
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(r:unpack(), 'custom-ok')
  assert_truthy(entered, 'custom Closure should receive the Lifetime body result')
end

-- Closure contracts are captured when a Lifetime is defined. Mutating the
-- original public protocol afterwards does not change the admitted Lifetime.
do
  local log = {}
  local protocol = Closure.protocol({
    name = 'captured-protocol',
    finish_op = function()
      log[#log + 1] = 'captured'
      return Op.always(true)
    end,
  })
  local value = { name = 'captured-closure-resource' }
  Lifetime.define(value, { closure = protocol })
  protocol.finish_op = function()
    log[#log + 1] = 'mutated'
    return Op.always(true)
  end
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(value))
  end)
  assert_eq(log[1], 'captured')
  assert_eq(log[2], nil)
end

-- Closure constructors reject malformed contracts at the public boundary.
do
  assert(not pcall(Closure.protocol, {
    name = 7,
    finish_op = function()
      return Op.always(true)
    end,
  }))
  assert(not pcall(Closure.protocol, { finish_op = true }))
  assert(not pcall(Closure.request_then_wait, function()
    return Op.always(true)
  end, function()
    return Op.always(true)
  end, 'not-options'))
  assert(not pcall(Closure.running, { on_body_result = true }))
  assert(not pcall(Closure.nursery, 'not-options'))
end

print('tests/test_closure.lua: ok')
