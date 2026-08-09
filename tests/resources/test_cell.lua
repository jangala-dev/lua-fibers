-- Cell resource contract tests.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local H = require('tests.resources.helpers')
local TC = require('tests.support.effect_helpers')

local function update_cell(cell, fn)
  return cell:read_op():and_then(Op.guard(function(old)
    local new = fn(old)
    return cell:write_op(new):map(function()
      return new, old
    end)
  end))
end

local function test_resource_observation_retries_independent_cell_updates()
  local opts, tags = H.tagging_host()
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  local cell = Cell.new(0):label('observation-cell')
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end):label('observation-updater-a')

  rt:spawn_raw(function()
    b = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end):label('observation-updater-b')

  H.assert_status(rt:run(), 'found', 'both contending cell updates eventually commit')
  H.assert_eq(cell._location.value, 2, 'stale resource attempt is retried against the fresh cell state')
  H.assert_eq(a, 1)
  H.assert_eq(b, 2)
end

local function test_resource_observation_retries_primary_before_or_else_fallback()
  local opts, tags = H.tagging_host()
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  local cell = Cell.new(0):label('observation-or-else-cell')
  local first, second

  rt:spawn_raw(function()
    first = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end):label('observation-or-else-first')

  rt:spawn_raw(function()
    second = rt:perform(update_cell(cell, function(v)
        return v + 1
      end)
      :map(function(v)
        return 'primary:' .. tostring(v)
      end)
      :or_else(Op.emit(TC.tag('observation.bad-fallback')):and_then(Op.always('fallback'))))
  end):label('observation-or-else-second')

  H.assert_status(rt:run(), 'found', 'stale primary is retried, not treated as absent')
  H.assert_eq(cell._location.value, 2)
  H.assert_eq(first, 1)
  H.assert_eq(second, 'primary:2')
  H.assert_eq(H.transaction_tags(rt), '', 'fallback effect is not discharged when primary is fresh-possible')
end

local function test_wait_until_and_match_contracts()
  local rt = Runtime.new()
  local cell = Cell.new({ state = 'idle', value = 0 }):label('wait-and-match-cell')
  local observed, projected, label

  rt:spawn_raw(function()
    observed = rt:perform(cell:wait_until_op(function(value)
      return value.state == 'ready'
    end))
    projected, label = rt:perform(cell:match_op(function(value)
      if value.state == 'ready' then
        return true, value.value, value.state
      end
    end))
  end):label('wait-and-match-observer')

  rt:spawn_raw(function()
    rt:perform(cell:write_op({ state = 'ready', value = 7 }))
  end):label('wait-and-match-writer')

  H.assert_status(rt:run(), 'found')
  H.assert_eq(observed.state, 'ready')
  H.assert_eq(observed.value, 7)
  H.assert_eq(projected, 7)
  H.assert_eq(label, 'ready')
end


local function test_shared_change_leaf_keeps_occurrence_state_separate()
  local Rendezvous = require('fibers.resource.rendezvous')
  local rt = Runtime.new()
  local cell = Cell.new(0):label('shared-change-leaf-cell')
  local first_done = Rendezvous.new():label('shared-change-leaf-first-done')
  local first_value, second_value

  rt:spawn_raw(function()
    first_value = rt:perform(cell:wait_until_op(function(value)
      return value >= 1
    end))
    rt:perform(first_done:put_op(true))
  end):label('shared-change-leaf-first')

  rt:spawn_raw(function()
    second_value = rt:perform(cell:wait_until_op(function(value)
      return value >= 2
    end))
  end):label('shared-change-leaf-second')

  rt:spawn_raw(function()
    rt:perform(cell:write_op(1))
    rt:perform(first_done:get_op())
    rt:perform(cell:write_op(2))
  end):label('shared-change-leaf-writer')

  H.assert_status(rt:run(), 'found')
  H.assert_eq(first_value, 1)
  H.assert_eq(second_value, 2)
end



local function test_expect_nil_is_a_valid_projected_value()
  local rt = Runtime.new()
  local cell = Cell.new(nil):label('nil-cell')
  local matched

  rt:spawn_raw(function()
    matched = rt:perform(cell:expect_op(nil))
  end):label('nil-cell-observer')

  H.assert_status(rt:run(), 'found')
  H.assert_eq(matched, true)
end

local tests = {
  test_expect_nil_is_a_valid_projected_value,
  test_shared_change_leaf_keeps_occurrence_state_separate,
  test_wait_until_and_match_contracts,
  test_resource_observation_retries_independent_cell_updates,
  test_resource_observation_retries_primary_before_or_else_fallback,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/resources/test_cell.lua: ok')
