package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Optional spectacle systems may fail without ending the live event. A
-- collecting supervisor retains those failures for diagnostics while the
-- headline sequence completes normally.

local fibers = require('fibers')
local closure = require('fibers.closure')

local event_result

local outer = fibers.try_run(function()
  event_result = fibers.try_scope({
    name = 'eclipse-festival',
    closure = closure.supervisor({ child_failure = 'collect' }),
  }, function(scope)
    scope:spawn(function()
      error('firework launcher 3 did not answer', 0)
    end, 'optional-fireworks')

    local moonrise = scope:spawn(function()
      return 'the artificial moon rose over the harbour'
    end, 'headline-moonrise')

    scope:spawn(function()
      return 'crowd ambience complete'
    end, 'crowd-ambience')

    return moonrise:await()
  end)
end)

assert(outer.ok)
assert(event_result.ok)
assert(event_result:unpack() == 'the artificial moon rose over the harbour')
assert(#event_result.report.child_failures == 1)
print(event_result:unpack())
print('optional failures:', #event_result.report.child_failures)
