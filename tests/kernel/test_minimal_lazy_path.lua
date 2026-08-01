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
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local EventQueue = require('fibers.resource.event_queue')
local Readiness = require('fibers.io.readiness')
local Signal = require('fibers.resource.signal')
local Clock = require('fibers.resource.clock')
local ManualHost = require('fibers.embed.manual')

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

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

-- Public value options are fresh opaque occurrences so unsupported mutation
-- remains local. Trusted executable leaves may still cache primitive options
-- whose descriptors are owned by the facility.
do
  truthy(Op.always() ~= Op.always(), 'empty always operation should be fresh')
  truthy(Op.always(true) ~= Op.always(true), 'true always operation should be fresh')
  truthy(Op.always(false) ~= Op.always(false), 'false always operation should be fresh')

  local rendezvous = Rendezvous.new('minimal-cached-rendezvous')
  eq(rendezvous:get_op(), rendezvous:get_op(), 'rendezvous get option should be cached')

  local cell = Cell.new(0, 'minimal-cached-cell')
  eq(cell:read_op(), cell:read_op(), 'cell read option should be cached')
  truthy(
    cell:read_op().spec and cell:read_op().spec._fibers_leaf_spec,
    'cached cell read should use an executable leaf specification'
  )
  local write = cell:write_op(7)
  eq(write.kind, 'primitive', 'cell write should be an executable primitive Op')
  eq(write.spec.kind, 'patch', 'cell write should carry its executable leaf directly')
  eq(write.arg.value, 7, 'cell write occurrence should carry its pre-bound argument')

  local counter = Counter.new(0, 'minimal-cached-counter')
  eq(counter:read_op(), counter:read_op(), 'counter read option should be cached')

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
  local rt = Runtime.new({ instrumentation = true })
  local total = 0
  local fiber = rt:spawn_raw(function()
    for i = 1, 20 do
      total = total + rt:perform(Op.always(i))
    end
  end, 'minimal-direct-perform')
  eq(rt:run().tag, 'found')
  eq(total, 210)
  eq(fiber.order, nil, 'completed fibre retained a request id')
  eq(fiber.op, nil, 'completed fibre retained an operation')
  eq(fiber.activation_root, nil, 'completed fibre retained an activation root')
  eq(fiber.guard_residuals, nil, 'fibre retained obsolete guard storage')
  eq(fiber.clock_values, nil, 'fibre retained obsolete clock storage')
  eq(rt._handoff_pool, nil, 'runtime should not allocate a perform hand-off pool')
end

-- Precise external dependencies survive unrelated deliveries, while the
-- resource actually named by the retained refutation invalidates it.
do
  local rt = Runtime.new({ instrumentation = true })
  local awaited = Signal.new('minimal-awaited-signal')
  local unrelated = Signal.new('minimal-unrelated-signal')
  local value
  rt:spawn_raw(function()
    value = rt:perform(awaited:wait_op())
  end, 'minimal-signal-waiter')
  eq(rt:run().tag, 'pending')
  local searches = counter(rt, 'searches')

  External.deliver(rt, External.external_feed(rt, unrelated), 'other')
  eq(rt:run().tag, 'pending')
  eq(counter(rt, 'searches'), searches, 'unrelated external delivery invalidated retained work')

  External.deliver(rt, External.external_feed(rt, awaited), 'ready')
  eq(rt:run().tag, 'found')
  eq(value, 'ready')
  truthy(counter(rt, 'searches') > searches, 'matching external resource did not invalidate retained work')
end

-- Timer dependencies remain valid strictly before their deadline and invalidate
-- at the deadline without relying on a runtime-wide epoch.
do
  local host = ManualHost.new({ now = 0 })
  local rt = Runtime.new({
    host = host,
    instrumentation = true,
  })
  local clock = Clock.new('minimal-timer')
  local fired
  rt:spawn_raw(function()
    fired = rt:perform(clock:at_op(10))
  end, 'minimal-timer-waiter')
  eq(rt:run().tag, 'pending')
  local searches = counter(rt, 'searches')
  eq(rt:run().tag, 'pending')
  eq(counter(rt, 'searches'), searches, 'unchanged timer was searched again')
  host._now = 9
  eq(rt:run().tag, 'pending')
  eq(counter(rt, 'searches'), searches, 'timer invalidated before its deadline')
  host._now = 10
  eq(rt:run().tag, 'found')
  eq(fired, 10)
  truthy(counter(rt, 'searches') > searches, 'timer did not invalidate at its deadline')
end

print('tests/test_minimal_lazy_path.lua: ok')
