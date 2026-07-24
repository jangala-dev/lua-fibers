package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A collecting supervisor lets independent children finish, retains every
-- failure in its report, and can still return an ordinary body result.

local fibers = require('fibers')
local policy = require('fibers.policy')

local inner

local outer = fibers.try_run(function()
  return fibers.try_scope({
    name = 'service-supervisor',
    policy = policy.supervisor({ child_failure = 'collect' }),
  }, function()
    fibers.spawn(function()
      error('telemetry failed', 0)
    end, 'telemetry')

    local healthy = fibers.spawn(function()
      return 42
    end, 'healthy-service')

    return healthy:await()
  end)
end)

assert(outer.ok)
inner = outer.values[1]
assert(inner.ok)
assert(inner:unpack() == 42)
assert(#inner.report.child_failures == 1)
print('body result:', inner:unpack(), 'collected failures:', #inner.report.child_failures)
