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
local WaitSet = require('fibers.embed.wait_set')
local PureHost = require('fibers.embed.pure')
local Common = require('tests.embedding.hosts.common')

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

  Common.assert_status(st, 'found')
  Common.assert_truthy(done, 'sleeping fibre should resume')
  Common.assert_eq(slept, 4, 'pure host should sleep until the reported deadline')
  Common.assert_eq(now, 14, 'fake clock should have advanced')
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

  Common.assert_status(st, 'pending')
  Common.assert_eq(st.host_reason, 'unsupported-waits')
  Common.assert_truthy(
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
  Common.assert_eq(deadline, 3)
  Common.assert_truthy(WaitSet.build({ { kind = 'timer', deadline = 1 }, { kind = 'external' } }).has_non_time)
end

print('tests/hosts/test_pure.lua: ok')
