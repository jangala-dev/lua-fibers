-- Cell resource contract tests.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Cell = require('et.resources.cell')
local H = require('tests.resources.test_helpers')

local function test_resource_freshness_retries_independent_cell_updates()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'freshness-cell')
  local a, b

  rt:spawn(function()
    a = rt:perform(cell:update_op(Op, function(v) return v + 1 end))
  end, 'freshness-updater-a')

  rt:spawn(function()
    b = rt:perform(cell:update_op(Op, function(v) return v + 1 end))
  end, 'freshness-updater-b')

  H.assert_status(rt:run(), 'found', 'both contending cell updates eventually commit')
  H.assert_eq(cell.value, 2, 'stale resource attempt is retried against the fresh cell state')
  H.assert_eq(a, 1)
  H.assert_eq(b, 2)
  H.assert_truthy((rt.stats.refreshes or 0) >= 1, 'resource freshness caused at least one frontier refresh')
end

local function test_resource_freshness_retries_primary_before_or_else_fallback()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'freshness-or-else-cell')
  local first, second

  rt:spawn(function()
    first = rt:perform(cell:update_op(Op, function(v) return v + 1 end))
  end, 'freshness-or-else-first')

  rt:spawn(function()
    second = rt:perform(
      cell:update_op(Op, function(v) return v + 1 end)
        :map(function(v) return 'primary:' .. tostring(v) end)
        :or_else(Op.emit({ tag = 'freshness.bad-fallback' }):and_then(function()
          return Op.always('fallback')
        end))
    )
  end, 'freshness-or-else-second')

  H.assert_status(rt:run(), 'found', 'stale primary is retried, not treated as absent')
  H.assert_eq(cell.value, 2)
  H.assert_eq(first, 1)
  H.assert_eq(second, 'primary:2')
  H.assert_eq(H.transaction_tags(rt), '', 'fallback consequence is not published when primary is fresh-possible')
  H.assert_truthy((rt.stats.refreshes or 0) >= 1, 'test exercised resource freshness under or_else')
end

local tests = {
  test_resource_freshness_retries_independent_cell_updates,
  test_resource_freshness_retries_primary_before_or_else_fallback,
}

for i = 1, #tests do tests[i]() end
print('tests/resources/test_cell.lua: ok')
