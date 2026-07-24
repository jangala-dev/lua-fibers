local fibers = require('fibers')
local Flow = require('fibers.resource.flow')
local Policy = require('fibers.policy')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')
local EventQueue = require('fibers.external.event_queue')

local cases = {}

local function add(tier, group, name, iterations, fn, opts)
  opts = opts or {}
  cases[#cases + 1] = {
    tier = tier,
    group = group,
    name = name,
    iterations = iterations,
    run = fn,
    description = opts.description,
  }
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function assert_ok(value, message)
  if not value then
    error(message or 'expected success', 2)
  end
end

local function drain(rt)
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  if status.tag ~= 'idle' and status.tag ~= 'quiescent' then
    error(
      'runtime did not drain: ' .. tostring(status.tag) .. '/' .. tostring(status.kind or status.reason),
      2
    )
  end
  return status
end

-- Simple: single-resource and low-branching paths.  These should remain cheap
-- enough to identify basic allocation, coroutine and store regressions.
add('simple', 'kernel', 'always perform', 4000, function(ctx, n)
  local rt = ctx:runtime()
  local sum = 0
  local op = Op.always(1)
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(op)
    end
  end, 'perf-always')
  drain(rt)
  assert_eq(sum, n)
  return n
end)

add('simple', 'scalar', 'serial read write', 1200, function(ctx, n)
  local rt = ctx:runtime()
  local scalar = Scalar.new(0, 'perf-scalar')
  local write_dependencies = Op.dependencies(scalar:write_op(0))
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(scalar:read_op():and_then(function(value)
        return scalar:write_op(value + 1)
      end, write_dependencies))
    end
  end, 'perf-scalar-fibre')
  drain(rt)
  assert_eq(scalar.value, n)
  return n
end)

add('simple', 'rendezvous', 'two fibre ping pong', 700, function(ctx, n)
  local rt = ctx:runtime()
  local request = Rendezvous.new('perf-ping')
  local reply = Rendezvous.new('perf-pong')
  local total = 0
  rt:spawn_raw(function()
    for i = 1, n do
      rt:perform(request:put_op(i))
      total = total + rt:perform(reply:get_op())
    end
  end, 'perf-ping-client')
  rt:spawn_raw(function()
    for _ = 1, n do
      local value = rt:perform(request:get_op())
      rt:perform(reply:put_op(value))
    end
  end, 'perf-ping-server')
  drain(rt)
  assert_eq(total, n * (n + 1) / 2)
  return n * 2
end)

add('simple', 'external', 'preloaded event queue', 1200, function(ctx, n)
  local rt = ctx:runtime()
  local queue = EventQueue.new('perf-events')
  local feed = rt:external_feed(queue)
  for i = 1, n do
    feed:set(i)
  end
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      total = total + rt:perform(queue:next_op())
    end
  end, 'perf-events-consumer')
  drain(rt)
  assert_eq(total, n * (n + 1) / 2)
  return n
end)

-- Moderate: products, continuations, flow state and structured task lifetimes.
add('moderate', 'product', 'internal then external rendezvous', 260, function(ctx, n)
  local rt = ctx:runtime()
  local inside = Rendezvous.new('perf-product-inside')
  local outside = Rendezvous.new('perf-product-outside')
  local outside_dependencies = Op.dependencies(outside:get_op())
  local total = 0
  rt:spawn_raw(function()
    for i = 1, n do
      local rows = rt:perform(Op.tensor({
        inside:get_op():and_then(function(value)
          return outside:get_op():map(function(other)
            return value + other
          end)
        end, outside_dependencies),
        inside:put_op(i),
      }))
      total = total + rows[1][1]
    end
  end, 'perf-product-main')
  rt:spawn_raw(function()
    for i = 1, n do
      rt:perform(outside:put_op(1000 + i))
    end
  end, 'perf-product-partner')
  drain(rt)
  assert_eq(total, n * 1000 + n * (n + 1))
  return n
end)

add('moderate', 'product', 'choice conflict backtracking', 320, function(ctx, n)
  local rt = ctx:runtime()
  local scalar = Scalar.new(0, 'perf-choice-conflict')
  local fallbacks = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      local rows = rt:perform(Op.tensor({
        scalar
          :write_op(1)
          :map(function()
            return 'write'
          end)
          :choice(Op.always('fallback')),
        scalar:write_op(2),
      }))
      if rows[1][1] == 'fallback' then
        fallbacks = fallbacks + 1
      end
    end
  end, 'perf-choice-conflict-fibre')
  drain(rt)
  assert_eq(fallbacks, n)
  assert_eq(scalar.value, 2)
  return n
end)

add('moderate', 'flow', 'sequential write read', 280, function(ctx, n)
  local rt = ctx:runtime()
  local flow = Flow.new({ name = 'perf-flow' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abcdefgh'))
      total = total + #rt:perform(outlet:read_exactly_op(8))
    end
  end, 'perf-flow-fibre')
  drain(rt)
  assert_eq(total, n * 8)
  return n * 2
end)

add('moderate', 'scope', 'spawn await settlement', 36, function(ctx, n)
  local total = 0
  local result = fibers.try_run(function()
    for i = 1, n do
      local task = fibers.spawn(function()
        return i
      end, { name = 'perf-task-' .. tostring(i) })
      total = total + fibers.perform(task:await_op())
    end
  end, ctx:run_options({ name = 'perf-scope' }))
  ctx:add_runtime(result.runtime)
  assert_ok(result.ok, tostring(result.report or result.reason))
  assert_eq(total, n * (n + 1) / 2)
  return n
end)

-- Complex: deliberate global coordination and adverse search frontiers.  These
-- are intended to expose branch growth and seed sensitivity, not merely report
-- a pleasant throughput figure.
add('complex', 'search', 'triple swap with decoy', 14, function(ctx, n)
  local completed = 0
  for round = 1, n do
    local rt = ctx:runtime()
    local ab = Rendezvous.new('perf-ab-' .. tostring(round))
    local bc = Rendezvous.new('perf-bc-' .. tostring(round))
    local ca = Rendezvous.new('perf-ca-' .. tostring(round))
    local a, b, c
    rt:spawn_raw(function()
      a = rt:perform(Op.all({ ab:put_op('A'), ca:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'perf-swap-a')
    rt:spawn_raw(function()
      b = rt:perform(Op.all({ bc:put_op('B'), ab:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'perf-swap-b')
    rt:spawn_raw(function()
      c = rt:perform(Op.all({ ca:put_op('C'), bc:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'perf-swap-c')
    rt:spawn_raw(function()
      rt:perform(ab:get_op())
    end, 'perf-decoy')
    drain(rt)
    assert_eq(a, 'C')
    assert_eq(b, 'A')
    assert_eq(c, 'B')
    completed = completed + 1
  end
  return completed
end)

add('complex', 'search', 'contended producers', 6, function(ctx, rounds)
  local producers = 8
  local messages = 4
  local completed = 0
  for round = 1, rounds do
    local rt = ctx:runtime()
    local ch = Rendezvous.new('perf-contention-' .. tostring(round))
    local total = 0
    for producer = 1, producers do
      rt:spawn_raw(function()
        for message = 1, messages do
          rt:perform(ch:put_op(producer * 100 + message))
        end
      end, 'perf-producer-' .. tostring(producer))
    end
    rt:spawn_raw(function()
      for _ = 1, producers * messages do
        total = total + rt:perform(ch:get_op())
      end
    end, 'perf-contention-consumer')
    drain(rt)
    assert_ok(total > 0)
    completed = completed + producers * messages
  end
  return completed
end)

add('complex', 'search', 'nursery rendezvous fanout seven', 1, function(ctx, rounds)
  local fanout = 7
  local completed = 0
  for round = 1, rounds do
    local total = 0
    local result = fibers.try_run(
      function()
        local ch = Rendezvous.new('perf-nursery-fanout-' .. tostring(round))
        for i = 1, fanout do
          fibers.spawn(function()
            fibers.perform(ch:put_op(i))
          end, 'perf-child-' .. tostring(i))
        end
        for _ = 1, fanout do
          total = total + fibers.perform(ch:get_op())
        end
      end,
      ctx:run_options({
        name = 'perf-nursery-fanout',
        policy = Policy.nursery({ name = 'perf-nursery-policy' }),
      })
    )
    ctx:add_runtime(result.runtime)
    assert_ok(result.ok, tostring(result.report or result.reason))
    assert_eq(total, fanout * (fanout + 1) / 2)
    completed = completed + fanout
  end
  return completed
end)

return cases
