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
local Sleep = require('fibers.sleep')
local FibersSignal = require('fibers.resource.signal')
local AutoIO = require('fibers.io.auto')
local ManualHost = require('fibers.embed.manual')
local WaitSet = require('fibers.embed.wait_set')
local PureHost = require('fibers.embed.pure')

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
    fibers.perform(Sleep.sleep_op(4))
    done = true
  end, { host = host }).runtime_status

  assert_status(st, 'found')
  assert_truthy(done, 'sleeping fiber should resume')
  assert_eq(slept, 4, 'pure host should sleep until the reported deadline')
  assert_eq(now, 14, 'fake clock should have advanced')
end

-- The pure host is deliberately limited.  It does not pretend to support external
-- waits or polling; unsupported waits are returned to the caller as pending.
do
  local signal
  local st = fibers.try_run(function()
    signal = FibersSignal.new():label('unsupported-host-source')
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
    st.interests and st.interests[1] and st.interests[1].kind == 'external',
    'pending status should report external wait'
  )
end

-- Host helper extracts the earliest time wait and ignores non-time waits.
do
  local deadline = WaitSet.build({
    { kind = 'external', key = 'x' },
    { kind = 'timer', deadline = 7 },
    { kind = 'timer', deadline = 3 },
  }).deadline
  assert_eq(deadline, 3)
end

-- Host selection returns complete, indivisible families.
do
  local manual = ManualHost.new({ now = 0 })
  assert_eq(manual.kind, 'manual')
  assert_truthy(type(manual._fibers_id) == 'string')
  assert_eq(manual.family, 'manual')
  assert_truthy(
    manual:supports('readiness'),
    'manual host should describe features'
  )
  assert_eq(manual.capabilities, nil)
  assert_eq(manual.features, nil)
  assert_eq(manual.providers, nil)
  assert_eq(manual.application, nil)
  assert_eq(manual.wait_domain, nil)
  assert_eq(manual.auto_advance_time, nil)

  local pure = PureHost.new({
    now = function()
      return 0
    end,
    sleep = function()
      return true
    end,
  })
  assert_eq(pure.kind, 'pure')
  assert_truthy(type(pure._fibers_id) == 'string')
  assert_eq(pure.family, 'pure')
  assert_eq(pure.capabilities, nil)
  assert_eq(pure.features, nil)
  assert_eq(pure.application, nil)

  local available = AutoIO.available()
  assert_truthy(type(available) == 'table' and #available > 0, 'AutoIO.available should list native I/O backends')

  assert_eq(manual.create_pipe, nil, 'manual host should expose only injected facilities')

  local injected = ManualHost.new({
    create_pipe = function(_self, opts)
      return opts and opts.label
    end,
  })
  assert_eq(injected:feature('pipe'), true)
  assert_eq(injected:create_pipe({ label = 'injected-pipe' }), 'injected-pipe')
end

print('tests/test_host.lua: ok')
