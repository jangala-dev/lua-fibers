-- Typed Machine transitions and RateLimiter facility.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')
local RateLimiter = require('examples.recipes.rate_limiter')
local Runtime = require('fibers.runtime')
local fibers = require('fibers')
local ManualHost = require('fibers.embed.manual')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
    )
  end
end
local function assert_near(actual, expected, eps, msg)
  eps = eps or 1e-9
  if math.abs(actual - expected) > eps then
    fail((msg or 'assert_near failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function test_cell_transition_serialises_parallel_updates()
  local rt = new_runtime()
  local s = StateMachine.new(0, 'cell-transition-each')
  local inc = StateMachine.update('test.cell.inc', function(v, payload)
    local next_value = v + payload.by
    return StateMachine.Ready.write(next_value, next_value)
  end)
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      s:transition_op(inc, { by = 1 }),
      s:transition_op(inc, { by = 1 }),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(s.value, 2)
  assert_eq(rows[1][1], 1)
  assert_eq(rows[2][1], 2)
end

local function test_rate_limiter_parallel_acquire_serialises_without_double_refill()
  local host = ManualHost.new({ now = 1 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 2, rate = 2, initial = 0, last = 0, name = 'rl-parallel' })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ rl:acquire_op(1), rl:acquire_op(1) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_near(rl.state.value.tokens, 0)
  assert_near(rl.state.value.last, 1)
end

local function test_rate_limiter_waits_until_enough_tokens()
  local host = ManualHost.new({ now = 0 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 1, rate = 1, initial = 0, last = 0, name = 'rl-wait' })
  local ok
  rt:spawn_raw(function()
    ok = rt:perform(rl:acquire_op(1))
  end, 'root')
  assert_status(External.drive(rt, { host = host }), 'found')
  assert_eq(ok, true)
  assert_near(host._now, 1)
  assert_near(rl.state.value.tokens, 0)
  assert_near(rl.state.value.last, 1)
end

local function test_rate_limiter_try_acquire_reports_deadline()
  local host = ManualHost.new({ now = 0 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 2, rate = 2, initial = 0, last = 0, name = 'rl-try' })
  local ok, deadline, available
  rt:spawn_raw(function()
    ok, deadline, available = rt:perform(rl:try_acquire_op(1))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(ok, false)
  assert_near(deadline, 0.5)
  assert_near(available, 0)
  assert_near(rl.state.value.tokens, 0)
  assert_near(rl.state.value.last, 0)
end

local function test_rate_limiter_available_is_observational()
  local host = ManualHost.new({ now = 1 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 3, rate = 2, initial = 0, last = 0, name = 'rl-available' })
  local available
  rt:spawn_raw(function()
    available = rt:perform(rl:available_op())
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_near(available, 2)
  assert_near(rl.state.value.tokens, 0, 1e-9, 'available_op should not commit a refill')
  assert_near(rl.state.value.last, 0)
end

local function test_cell_transition_ordering_is_direct_and_deterministic()
  local s = StateMachine.new('', 'cell-ordering')
  local first = StateMachine.update('test.order.first', function(v)
    return StateMachine.Ready.write(v .. 'b', 'first')
  end)
  local second = StateMachine.update('test.order.second', function(v)
    return StateMachine.Ready.write(v .. 'a', 'second')
  end, 100)
  local rows
  local rt = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ s:transition_op(second), s:transition_op(first) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(s.value, 'ba')
  assert_eq(rows[1][1], 'second')
  assert_eq(rows[2][1], 'first')
end

local function test_cell_transition_ordering_controls_select_handoff()
  local s = StateMachine.new(0, 'cell-select-ordering')
  local supply = StateMachine.update('test.order.supply', function(v)
    return StateMachine.Ready.write(v + 1, true)
  end)
  local take = StateMachine.select('test.order.take', function(v)
    if v <= 0 then
      return StateMachine.Wait
    end
    return StateMachine.Ready.write(v - 1, v)
  end, 100)
  local rows
  local rt = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ s:transition_op(take), s:transition_op(supply) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 1)
  assert_eq(rows[2][1], true)
  assert_eq(s.value, 0)
end

local function test_cell_transition_payload_validation()
  local s = StateMachine.new(0, 'cell-validation')
  local checked = StateMachine.update('test.validation', function(v, payload)
    return StateMachine.Ready.write(v + payload.n, true)
  end, nil, function(payload)
    if type(payload.n) ~= 'number' or payload.n <= 0 then
      error('n must be positive', 2)
    end
  end)
  local ok = pcall(function()
    s:transition_op(checked, { n = 0 })
  end)
  assert_eq(ok, false, 'invalid transition payload should fail at construction time')
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(s:transition_op(checked, { n = 2 }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(s.value, 2)
end

local tests = {
  test_cell_transition_serialises_parallel_updates,
  test_rate_limiter_parallel_acquire_serialises_without_double_refill,
  test_rate_limiter_waits_until_enough_tokens,
  test_rate_limiter_try_acquire_reports_deadline,
  test_rate_limiter_available_is_observational,
}

for i = 1, #tests do
  tests[i]()
end
print('examples/recipes/tests/test_cell_and_rate_limiter.lua: ok')
