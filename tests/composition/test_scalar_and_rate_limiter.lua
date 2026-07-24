-- Typed Scalar transitions and RateLimiter facility.

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

local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local RateLimiter = require('examples.recipes.rate_limiter')
local Runtime = require('fibers.runtime')
local fibers = require('fibers')
local Host = require('fibers.host')

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

local function test_scalar_transition_serialises_parallel_updates()
  local rt = new_runtime()
  local s = Scalar.new(0, 'scalar-transition-all')
  local inc = Scalar.transition({
    name = 'test.scalar.inc',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    step = function(v, payload)
      local next_value = v + payload.by
      return Scalar.Ready.write(next_value, next_value)
    end,
  })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({
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
  local host = Host.manual({ now = 1 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 2, rate = 2, initial = 0, last = 0, name = 'rl-parallel' })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ rl:acquire_op(1), rl:acquire_op(1) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_near(rl.state.value.tokens, 0)
  assert_near(rl.state.value.last, 1)
end

local function test_rate_limiter_waits_until_enough_tokens()
  local host = Host.manual({ now = 0 })
  local rt = Runtime.new({ host = host })
  local rl = RateLimiter.new({ capacity = 1, rate = 1, initial = 0, last = 0, name = 'rl-wait' })
  local ok
  rt:spawn_raw(function()
    ok = rt:perform(rl:acquire_op(1))
  end, 'root')
  assert_status(rt:drive({ host = host }), 'found')
  assert_eq(ok, true)
  assert_near(host._now, 1)
  assert_near(rl.state.value.tokens, 0)
  assert_near(rl.state.value.last, 1)
end

local function test_rate_limiter_try_acquire_reports_deadline()
  local host = Host.manual({ now = 0 })
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
  local host = Host.manual({ now = 1 })
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

local function test_scalar_transition_ordering_is_direct_and_deterministic()
  local s = Scalar.new('', 'scalar-ordering')
  local first = Scalar.transition({
    name = 'test.order.first',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    order = 0,
    step = function(v)
      return Scalar.Ready.write(v .. 'b', 'first')
    end,
  })
  local second = Scalar.transition({
    name = 'test.order.second',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    order = 100,
    step = function(v)
      return Scalar.Ready.write(v .. 'a', 'second')
    end,
  })
  local rows
  local rt = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({ s:transition_op(second), s:transition_op(first) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(s.value, 'ba')
  assert_eq(rows[1][1], 'second')
  assert_eq(rows[2][1], 'first')
end

local function test_scalar_transition_ordering_controls_select_handoff()
  local s = Scalar.new(0, 'scalar-select-ordering')
  local supply = Scalar.transition({
    name = 'test.order.supply',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    order = 0,
    step = function(v)
      return Scalar.Ready.write(v + 1, true)
    end,
  })
  local take = Scalar.transition({
    name = 'test.order.take',
    mode = 'select',
    accepts_supply = true,
    supplies = 'any',
    order = 100,
    step = function(v)
      if v <= 0 then
        return Scalar.Wait
      end
      return Scalar.Ready.write(v - 1, v)
    end,
  })
  local rows
  local rt = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({ s:transition_op(take), s:transition_op(supply) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 1)
  assert_eq(rows[2][1], true)
  assert_eq(s.value, 0)
end

local function test_scalar_transition_payload_validation()
  local s = Scalar.new(0, 'scalar-validation')
  local checked = Scalar.transition({
    name = 'test.validation',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    validate = function(payload)
      if type(payload.n) ~= 'number' or payload.n <= 0 then
        error('n must be positive', 2)
      end
    end,
    step = function(v, payload)
      return Scalar.Ready.write(v + payload.n, true)
    end,
  })
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
  test_scalar_transition_serialises_parallel_updates,
  test_rate_limiter_parallel_acquire_serialises_without_double_refill,
  test_rate_limiter_waits_until_enough_tokens,
  test_rate_limiter_try_acquire_reports_deadline,
  test_rate_limiter_available_is_observational,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/test_scalar_transitions_rate_limiter.lua: ok')
