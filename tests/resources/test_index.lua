-- Ordered Index allocation laws.
-- These tests exercise distinct witnessed selection, ordered allocation,
-- linear consumption, and the each/together supply distinction.

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
local Index = require('fibers.resource.index')
local Runtime = require('fibers.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_nil(value, msg)
  if value ~= nil then
    fail((msg or 'expected nil') .. ': got ' .. tostring(value))
  end
end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
    )
  end
end

local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function seeded_index(name)
  return Index.from({
    { key = 'a', rank = 1, value = 'A' },
    { key = 'b', rank = 2, value = 'B' },
    { key = 'c', rank = 3, value = 'C' },
  }, name)
end

local function test_two_parallel_pop_first_claims_get_distinct_concrete_values()
  local rt = new_runtime()
  local ix = seeded_index('idx-pop2')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:pop_first_op():map(function(e)
        return e.key, e.value
      end),
      ix:pop_first_op():map(function(e)
        return e.key, e.value
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'a')
  assert_eq(rows[1][2], 'A')
  assert_eq(rows[2][1], 'b')
  assert_eq(rows[2][2], 'B')
  assert_nil(ix.entries.a, 'first entry should be removed once')
  assert_nil(ix.entries.b, 'second entry should be removed once')
  assert_eq(ix.entries.c.value, 'C')
end

local function test_parallel_pop_last_claims_get_distinct_tail_values()
  local rt = new_runtime()
  local ix = seeded_index('idx-poplast2')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:pop_last_op():map(function(e)
        return e.key
      end),
      ix:pop_last_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'c')
  assert_eq(rows[2][1], 'b')
  assert_nil(ix.entries.c)
  assert_nil(ix.entries.b)
  assert_eq(ix.entries.a.value, 'A')
end

local function test_remove_plus_pop_skips_removed_head()
  local rt = new_runtime()
  local ix = seeded_index('idx-remove-pop')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:remove_op('a'),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'b')
  assert_nil(ix.entries.a)
  assert_nil(ix.entries.b)
  assert_eq(ix.entries.c.value, 'C')
end

local function test_pop_first_and_then_receives_concrete_lua_entry()
  local rt = new_runtime()
  local ix = seeded_index('idx-bind')
  local out

  rt:spawn_raw(function()
    out = rt:perform(ix:pop_first_op():and_then(Op.guard(function(e)
      assert_eq(type(e), 'table')
      assert_eq(e.key, 'a')
      return Op.always('got:' .. e.value)
    end)))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(out, 'got:A')
end

local function test_pop_then_reinsert_same_key_is_sequential_replacement()
  local rt = new_runtime()
  local ix = Index.from({ { key = 'a', rank = 1, value = 'A' } }, 'idx-pop-reinsert')
  local out

  rt:spawn_raw(function()
    out = rt:perform(ix:pop_first_op():and_then(Op.guard(function(e)
      return ix:insert_op(e.key, e.rank, 'A2'):map(function()
        return e.key
      end)
    end)))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(out, 'a')
  assert_eq(
    ix.entries.a.value,
    'A2',
    'later insert in continuation should follow selected remove sequentially'
  )
end

local function test_empty_index_claim_uses_absence_fallback()
  local rt = new_runtime()
  local ix = Index.new('idx-empty')
  local out

  rt:spawn_raw(function()
    out = rt:perform(ix:pop_first_op():or_else(Op.always('empty')))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(out, 'empty')
end

local function test_insert_plus_pop_first_consumes_same_world_insert()
  local rt = new_runtime()
  local ix = Index.new('idx-insert-pop-empty')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():map(function(e)
        return e.key, e.value
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'z')
  assert_eq(rows[2][2], 'Z')
  assert_nil(ix.entries.z, 'same-world inserted entry should be consumed by pop')
end

local function test_insert_plus_pop_first_uses_projected_order()
  local rt = new_runtime()
  local ix = seeded_index('idx-insert-pop-order')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'z')
  assert_nil(ix.entries.z)
  assert_eq(ix.entries.a.value, 'A', 'existing head should remain because inserted z was first')
end

local function test_insert_plus_two_pops_allocates_insert_then_existing()
  local rt = new_runtime()
  local ix = seeded_index('idx-insert-pop2')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'z')
  assert_eq(rows[3][1], 'a')
  assert_nil(ix.entries.z)
  assert_nil(ix.entries.a)
  assert_eq(ix.entries.b.value, 'B')
end

local function test_absence_sees_projected_insert()
  local rt = new_runtime()
  local ix = Index.new('idx-absence-insert')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():or_else(Op.always('empty')),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1].key, 'z')
  assert_nil(ix.entries.z)
end

local function test_pop_first_and_pop_last_fail_as_one_world_with_one_entry()
  local rt = new_runtime({ quiet_deadlock = true })
  local ix = Index.from({ { key = 'a', rank = 1, value = 'A' } }, 'idx-one-entry-two-ends')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:pop_first_op(),
      ix:pop_last_op(),
    }))
  end, 'root')

  local status = rt:run()
  if status and status.tag == 'found' then
    fail('two consuming selections from one entry should not commit')
  end
  assert_eq(ix.entries.a.value, 'A', 'failed together should leave entry intact')
end

local function test_each_insert_does_not_supply_pop_but_commits_insert()
  local rt = new_runtime()
  local ix = Index.new('idx-each-insert-pop')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():or_else(Op.always('empty')),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'empty')
  assert_eq(ix.entries.z.value, 'Z', 'each sibling insert should remain committed')
end

local function test_together_insert_supplies_pop_and_consumes_insert()
  local rt = new_runtime()
  local ix = Index.new('idx-together-insert-pop-law')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ix:insert_op('z', 0, 'Z'),
      ix:pop_first_op():or_else(Op.always('empty')),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1].key, 'z')
  assert_nil(ix.entries.z, 'together sibling insert may be consumed as handoff')
end

local function test_each_parallel_pops_allocate_shared_committed_stock()
  local rt = new_runtime()
  local ix = seeded_index('idx-each-two-pops')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      ix:pop_first_op():map(function(e)
        return e.key
      end),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'a')
  assert_eq(rows[2][1], 'b')
  assert_nil(ix.entries.a)
  assert_nil(ix.entries.b)
  assert_eq(ix.entries.c.value, 'C')
end

local function test_each_remove_constrains_sibling_pop_without_supplying()
  local rt = new_runtime()
  local ix = seeded_index('idx-each-remove-pop')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      ix:remove_op('a'),
      ix:pop_first_op():map(function(e)
        return e.key
      end),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'b')
  assert_nil(ix.entries.a)
  assert_nil(ix.entries.b)
  assert_eq(ix.entries.c.value, 'C')
end


local function test_equal_rank_entries_use_insertion_sequence_without_tostring()
  local rt = new_runtime()
  local ix = Index.new('idx-equal-rank-sequence')
  local key_a = setmetatable({}, { __tostring = function() error('key tostring must not order Index entries') end })
  local key_b = setmetatable({}, { __tostring = function() error('key tostring must not order Index entries') end })
  local rows

  rt:spawn_raw(function()
    rt:perform(ix:insert_op(key_a, 1, 'A'))
    rt:perform(ix:insert_op(key_b, 1, 'B'))
    rows = rt:perform(Op.together({
      ix:pop_first_op(),
      ix:pop_first_op(),
    }))
  end, 'root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1].key, key_a)
  assert_eq(rows[1][1].value, 'A')
  assert_eq(rows[2][1].key, key_b)
  assert_eq(rows[2][1].value, 'B')
end

local function test_import_rejects_ambiguous_rank_sequence()
  local ok, err = pcall(function()
    Index.from({
      { key = 'a', rank = 1, seq = 4, value = 'A' },
      { key = 'b', rank = 1, seq = 4, value = 'B' },
    }, 'idx-ambiguous-order')
  end)
  if ok then fail('ambiguous Index ordering should be rejected') end
  if not tostring(err):find('unique %(rank, sequence%) pairs') then
    fail('unexpected ambiguous-order error: ' .. tostring(err))
  end
end

local tests = {
  test_two_parallel_pop_first_claims_get_distinct_concrete_values,
  test_parallel_pop_last_claims_get_distinct_tail_values,
  test_remove_plus_pop_skips_removed_head,
  test_pop_first_and_then_receives_concrete_lua_entry,
  test_pop_then_reinsert_same_key_is_sequential_replacement,
  test_empty_index_claim_uses_absence_fallback,
  test_insert_plus_pop_first_consumes_same_world_insert,
  test_insert_plus_pop_first_uses_projected_order,
  test_insert_plus_two_pops_allocates_insert_then_existing,
  test_absence_sees_projected_insert,
  test_pop_first_and_pop_last_fail_as_one_world_with_one_entry,
  test_each_insert_does_not_supply_pop_but_commits_insert,
  test_together_insert_supplies_pop_and_consumes_insert,
  test_each_parallel_pops_allocate_shared_committed_stock,
  test_each_remove_constrains_sibling_pop_without_supplying,
  test_equal_rank_entries_use_insertion_sequence_without_tostring,
  test_import_rejects_ambiguous_rank_sequence,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/test_claim_index.lua: ok')
