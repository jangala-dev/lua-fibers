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


local function perform_one(op)
  local rt, result = Runtime.new()
  rt:spawn_raw(function() result = rt:perform(op) end)
  H.assert_status(rt:run(), 'found')
  return result
end

local function test_managed_values_capture_and_expose_tables()
  local source = { state = 'idle', nested = { count = 1 } }
  local cell = Cell.new(source)
  source.nested.count = 99

  local first = perform_one(cell:read_op())
  H.assert_eq(first.nested.count, 1, 'constructor captures the initial value')
  first.nested.count = 77
  local second = perform_one(cell:read_op())
  H.assert_eq(second.nested.count, 1, 'read results cannot mutate authoritative state')
  H.assert_eq(cell._location.version, 0, 'ordinary Lua mutation cannot change a managed version')
end

local function test_write_and_expect_capture_occurrence_values()
  local cell = Cell.new({ value = 0 })
  local next_value = { value = 4 }
  local write = cell:write_op(next_value)
  next_value.value = 9
  perform_one(write)
  H.assert_eq(perform_one(cell:read_op()).value, 4, 'write option captures at construction')

  local expected = { value = 4 }
  local expect = cell:expect_op(expected)
  expected.value = 100
  H.assert_eq(perform_one(expect), true, 'expect uses captured structural equality')
end

local function test_wait_until_predicate_mutation_preserves_observed_result()
  local cell = Cell.new({ ready = true, nested = { count = 1 } })
  local observed = perform_one(cell:wait_until_op(function(value)
    value.ready = false
    value.nested.count = 50
    return true
  end))

  H.assert_eq(observed.ready, true, 'wait_until returns the value which was observed')
  H.assert_eq(observed.nested.count, 1, 'predicate-local mutation does not rewrite the returned observation')
  H.assert_eq(perform_one(cell:read_op()).nested.count, 1, 'predicate mutation cannot escape')
  H.assert_eq(cell._location.version, 0)
end

local function test_alias_mutation_cannot_change_certified_fallback()
  local source = { gate = { ready = false } }
  local expected = { gate = { ready = true } }
  local cell = Cell.new(source)
  local decision = cell:expect_op(expected)
    :and_then(Op.always('primary'))
    :or_else(Op.always('fallback'))

  -- Mutate every ordinary-Lua alias which participated in construction or
  -- observation. None of these mutations is a versioned managed-state change.
  source.gate.ready = true
  expected.gate.ready = false
  local exposed = perform_one(cell:read_op())
  exposed.gate.ready = true

  H.assert_eq(perform_one(decision), 'fallback', 'aliases cannot invalidate certified present absence')
  H.assert_eq(perform_one(cell:read_op()).gate.ready, false)
  H.assert_eq(cell._location.version, 0)
end

local function test_equal_parallel_replacements_compose_structurally()
  local cell = Cell.new({ value = 0 })
  local rows
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ cell:write_op({ value = 1 }), cell:write_op({ value = 1 }) }))
  end)
  H.assert_status(rt:run(), 'found')
  H.assert_eq(rows[1][1], true)
  H.assert_eq(rows[2][1], true)
  H.assert_eq(perform_one(cell:read_op()).value, 1)
end

local function test_managed_value_rejections_are_immediate()
  local function rejects(fn, needle)
    local ok, err = pcall(fn)
    H.assert_eq(ok, false)
    if not tostring(err):find(needle, 1, true) then error('unexpected managed-value error: ' .. tostring(err), 2) end
  end

  rejects(function() Cell.new({ callback = function() end }) end, 'forbidden function value')
  rejects(function() Cell.new(setmetatable({ value = 1 }, {})) end, 'table with a metatable')
  local cycle = {}; cycle.self = cycle
  rejects(function() Cell.new(cycle) end, 'contains a cycle')
  local shared = { value = 1 }
  rejects(function() Cell.new({ a = shared, b = shared }) end, 'shared table reference')
  local key = {}
  rejects(function() Cell.new({ [key] = true }) end, 'forbidden table key')

  local cell = Cell.new(0)
  rejects(function() cell:write_op({ bad = coroutine.create(function() end) }) end, 'forbidden thread value')
end

local tests = {
  test_managed_value_rejections_are_immediate,
  test_equal_parallel_replacements_compose_structurally,
  test_alias_mutation_cannot_change_certified_fallback,
  test_wait_until_predicate_mutation_preserves_observed_result,
  test_write_and_expect_capture_occurrence_values,
  test_managed_values_capture_and_expose_tables,
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
