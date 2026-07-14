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
local FibersSignal = require('fibers.external.signal')
local Host = require('fibers.host')
local PureHost = require('fibers.host.pure')

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
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end

-- The pure host drives time waits without busy-waiting in user code.  The test
-- supplies a fake sleep function so the suite does not actually pause.
do
  local now = 10
  local slept
  local host = PureHost.new({
    now = function()
      return now
    end,
    sleep = function(seconds)
      slept = seconds
      now = now + seconds
      return true
    end,
  })

  local done = false
  local st = fibers.try_run(function()
    fibers.perform(fibers.sleep_op(4))
    done = true
  end, { host = host }).runtime_status

  assert_status(st, 'found')
  assert_truthy(done, 'sleeping fibre should resume')
  assert_eq(slept, 4, 'pure host should sleep until the reported deadline')
  assert_eq(now, 14, 'fake clock should have advanced')
end

-- The pure host is deliberately limited.  It does not pretend to support external
-- waits or polling; unsupported waits are returned to the caller as pending.
do
  local signal
  local st = fibers.try_run(function()
    signal = FibersSignal.new('unsupported-host-source')
    fibers.perform(signal:wait_op())
  end, {
    host = PureHost.new({
      now = function()
        return 0
      end,
      sleep = function()
        error('should not sleep')
      end,
    }),
  }).runtime_status

  assert_status(st, 'pending')
  assert_eq(st.host_reason, 'unsupported-waits')
  assert_truthy(
    st.waits and st.waits[1] and st.waits[1].kind == 'external',
    'pending status should report external wait'
  )
end

-- Host helper extracts the earliest time wait and ignores non-time waits.
do
  local deadline = Host.earliest_deadline({
    { kind = 'external', key = 'x' },
    { kind = 'timer', deadline = 7 },
    { kind = 'timer', deadline = 3 },
  })
  assert_eq(deadline, 3)
  assert_truthy(
    Host.has_non_time_waits({ { kind = 'timer', deadline = 1 }, { kind = 'external' } })
  )
end

-- Host selection returns complete families; fd selection remains low-level.
do
  local manual = Host.manual({ now = 0 })
  assert_eq(manual.name, 'manual')
  assert_eq(manual.family, 'manual')
  assert_truthy(
    manual.capabilities and manual.capabilities.readiness,
    'manual host should describe capabilities'
  )

  local pure = Host.select('pure', {
    now = function()
      return 0
    end,
    sleep = function()
      return true
    end,
  })
  assert_eq(pure.name, 'pure')
  assert_eq(pure.family, 'pure')

  local available = Host.available()
  assert_truthy(
    type(available) == 'table' and #available > 0,
    'host.available should list selectable hosts'
  )

  local fd_registry = require('fibers.host.fd')
  assert_truthy(type(fd_registry.select) == 'function', 'host.fd should be a registry/selector')
end

print('tests/test_host.lua: ok')
