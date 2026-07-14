-- Scalar resource contract tests.

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
local Scalar = require('fibers.scalar')
local H = require('tests.resources.test_helpers')
local TC = require('tests.support.effect_helpers')

local function update_scalar(scalar, fn)
  return scalar:read_op():and_then(function(old)
    local new = fn(old)
    return scalar:write_op(new):map(function()
      return new, old
    end)
  end)
end

local function test_resource_observation_retries_independent_scalar_updates()
  local opts, tags = H.tagging_host()
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  local scalar = Scalar.new(0, 'observation-scalar')
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(update_scalar(scalar, function(v)
      return v + 1
    end))
  end, 'observation-updater-a')

  rt:spawn_raw(function()
    b = rt:perform(update_scalar(scalar, function(v)
      return v + 1
    end))
  end, 'observation-updater-b')

  H.assert_status(rt:run(), 'found', 'both contending scalar updates eventually commit')
  H.assert_eq(scalar.value, 2, 'stale resource attempt is retried against the fresh scalar state')
  H.assert_eq(a, 1)
  H.assert_eq(b, 2)
end

local function test_resource_observation_retries_primary_before_or_else_fallback()
  local opts, tags = H.tagging_host()
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  local scalar = Scalar.new(0, 'observation-or-else-scalar')
  local first, second

  rt:spawn_raw(function()
    first = rt:perform(update_scalar(scalar, function(v)
      return v + 1
    end))
  end, 'observation-or-else-first')

  rt:spawn_raw(function()
    second = rt:perform(update_scalar(scalar, function(v)
        return v + 1
      end)
      :map(function(v)
        return 'primary:' .. tostring(v)
      end)
      :or_else(Op.emit(TC.tag('observation.bad-fallback')):and_then(function()
        return Op.always('fallback')
      end)))
  end, 'observation-or-else-second')

  H.assert_status(rt:run(), 'found', 'stale primary is retried, not treated as absent')
  H.assert_eq(scalar.value, 2)
  H.assert_eq(first, 1)
  H.assert_eq(second, 'primary:2')
  H.assert_eq(H.transaction_tags(rt), '', 'fallback effect is not discharged when primary is fresh-possible')
end

local tests = {
  test_resource_observation_retries_independent_scalar_updates,
  test_resource_observation_retries_primary_before_or_else_fallback,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/resources/test_scalar.lua: ok')
