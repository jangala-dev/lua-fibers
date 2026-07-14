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
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.scalar')
local Counter = require('fibers.resource.counter')
local EventQueue = require('fibers.external.event_queue')
local Readiness = require('fibers.external.readiness')
local Signal = require('fibers.external.signal')
local Clock = require('fibers.external.clock')
local Host = require('fibers.host')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- Immutable common options are constructed once per resource.  This is an
-- API-preserving allocation reduction: callers still receive ordinary Ops.
do
  eq(Op.always(), Op.always(), 'empty always operation should be interned')
  eq(Op.always(true), Op.always(true), 'true always operation should be interned')
  eq(Op.always(false), Op.always(false), 'false always operation should be interned')

  local rendezvous = Rendezvous.new('minimal-cached-rendezvous')
  eq(rendezvous:get_op(), rendezvous:get_op(), 'rendezvous get option should be cached')

  local scalar = Scalar.new(0, 'minimal-cached-scalar')
  eq(scalar:read_op(), scalar:read_op(), 'scalar read option should be cached')
  eq(scalar:snapshot_op(), scalar:snapshot_op(), 'scalar snapshot option should be cached')
  truthy(scalar:read_op()._fibers_program, 'cached scalar read should use compact primitive programme')

  local counter = Counter.new(0, 'minimal-cached-counter')
  eq(counter:read_op(), counter:read_op(), 'counter read option should be cached')
  eq(counter:state_op(), counter:state_op(), 'counter state option should be cached')

  local queue = EventQueue.new('minimal-cached-events')
  eq(queue:next_op(), queue:next_op(), 'event queue next option should be cached')
  eq(queue:_drain_op(), queue:_drain_op(), 'event queue drain option should be cached')

  local readiness = Readiness.new(1, 'read', 'minimal-cached-readiness')
  eq(readiness:readable_op(), readiness:readable_op(), 'read readiness option should be cached')
  eq(readiness:writable_op(), readiness:writable_op(), 'write readiness option should be cached')

  local signal = Signal.new('minimal-cached-signal')
  eq(signal:wait_op(), signal:wait_op(), 'signal wait option should be cached')
end

-- Perform uses a shared multi-value coroutine protocol and stores the one
-- outstanding request directly on the fibre.  No per-perform hand-off object
-- or response record is retained.
do
  local rt = Runtime.new({ machine = 'trail', instrumentation = true })
  local total = 0
  local fiber = rt:spawn_raw(function()
    for i = 1, 20 do
      total = total + rt:perform(Op.always(i))
    end
  end, 'minimal-direct-perform')
  eq(rt:run().tag, 'found')
  eq(total, 210)
  eq(fiber.id, nil, 'completed fibre retained a request id')
  eq(fiber.op, nil, 'completed fibre retained an operation')
  eq(fiber.activation_root, nil, 'completed fibre retained an activation root')
  eq(next(fiber.memo), nil, 'completed fibre retained callback memo values')
  eq(rt._handoff_pool, nil, 'runtime should not allocate a perform hand-off pool')
end

-- Exact state keys appear only after a cheap fingerprint repeats.  The filter
-- cannot justify a memo hit by itself; the existing exact signature remains the
-- proof of equality.
do
  local rt = Runtime.new({
    machine = 'trail',
    instrumentation = true,
    plan_reuse = false,
    state_memoization = true,
    refutation_cache = false,
    state_memoization_min_steps = 0,
    state_memoization_min_intents = 0,
  })
  local blocked = Rendezvous.new('minimal-fingerprint'):get_op()
  local alternatives = {}
  for i = 1, 32 do
    alternatives[i] = blocked
  end
  rt:spawn_raw(function()
    rt:perform(Op.choice(alternatives))
  end, 'minimal-fingerprint')
  eq(rt:run().tag, 'quiescent')
  local counters = rt:instrumentation_snapshot().counters
  truthy((counters.state_fingerprint_probes or 0) > 0, 'state fingerprints were not probed')
  truthy((counters.state_fingerprint_repeats or 0) > 0, 'repeated state fingerprint was not observed')
  truthy((counters.state_memo_hits or 0) > 0, 'exact memoisation did not activate after repetition')
end

-- Precise external dependencies survive unrelated deliveries, while the
-- resource actually named by the retained refutation invalidates it.
do
  local rt = Runtime.new({ machine = 'trail', instrumentation = true, plan_reuse_threshold = 1 })
  local awaited = Signal.new('minimal-awaited-signal')
  local unrelated = Signal.new('minimal-unrelated-signal')
  local value
  rt:spawn_raw(function()
    value = rt:perform(awaited:wait_op())
  end, 'minimal-signal-waiter')
  eq(rt:run().tag, 'pending')
  local plans = rt.stats.plans

  rt:deliver(rt:external_feed(unrelated), 'other')
  eq(rt:run().tag, 'pending')
  eq(rt.stats.plans, plans, 'unrelated external delivery invalidated retained work')

  rt:deliver(rt:external_feed(awaited), 'ready')
  eq(rt:run().tag, 'found')
  eq(value, 'ready')
  truthy(rt.stats.plans > plans, 'matching external resource did not invalidate retained work')
end

-- Timer dependencies remain valid strictly before their deadline and invalidate
-- at the deadline without relying on a runtime-wide epoch.
do
  local host = Host.manual({ now = 0 })
  local rt = Runtime.new({
    machine = 'trail',
    host = host,
    instrumentation = true,
    plan_reuse_threshold = 1,
  })
  local clock = Clock.new('minimal-timer')
  local fired
  rt:spawn_raw(function()
    fired = rt:perform(clock:at_op(10))
  end, 'minimal-timer-waiter')
  eq(rt:run().tag, 'pending')
  local plans = rt.stats.plans
  eq(rt:run().tag, 'pending')
  eq(rt.stats.plans, plans, 'unchanged timer was searched again')
  host._now = 9
  eq(rt:run().tag, 'pending')
  eq(rt.stats.plans, plans, 'timer invalidated before its deadline')
  host._now = 10
  eq(rt:run().tag, 'found')
  eq(fired, true)
  truthy(rt.stats.plans > plans, 'timer did not invalidate at its deadline')
end

print('tests/test_minimal_lazy_path.lua: ok')
