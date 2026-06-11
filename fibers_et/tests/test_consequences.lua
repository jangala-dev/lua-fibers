-- Typed consequence obligation protocol tests.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Cell = require('fibers.base.cell')
local TC = require('tests.consequence_helpers')

local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg)
  if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_error_kind(ok, err, kind, msg)
  if ok then fail((msg or 'expected error') .. ': call succeeded') end
  if type(err) ~= 'table' or err.kind ~= kind then
    fail((msg or 'wrong error kind') .. ': expected ' .. tostring(kind) .. ', got ' .. tostring(type(err) == 'table' and err.kind or err))
  end
end
local function assert_uncommitted(st, msg)
  local tag = st and st.tag
  if tag ~= 'absent' and tag ~= 'pending' and tag ~= 'reject_candidate' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local vals = { n = 0 }
  rt:spawn_raw(function() vals = pack_(rt:perform(op)) end, 'one-perform')
  return rt:run(), vals, rt
end

local function test_emit_accepts_only_typed_consequences()
  local ok, err = pcall(function() return Op.emit({ tag = 'raw' }) end)
  assert_eq(ok, false, 'raw emit should fail')
  assert_truthy(tostring(err):match('typed consequence'), 'raw emit error explains expectation')
end

local function test_duplicate_obligations_merge_to_one_publication()
  local calls = {}
  local rt = Runtime.new({
    host = {
      test_tag = function(tag) calls[#calls + 1] = tag end,
    },
  })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.all({
      Op.emit(TC.tag('dup')),
      Op.emit(TC.tag('dup')),
    }))
  end, 'duplicate-consequence')

  local st = rt:run()
  assert_eq(st.tag, 'found')
  assert_truthy(got, 'participant resumed')
  assert_eq(#calls, 1, 'duplicate same-key obligations publish once')
  assert_eq(calls[1], 'dup')
  assert_eq(#rt.published_consequences, 1)
  assert_eq(#rt.published_consequences[1].obligation, 1)
end

local function test_conflicting_obligations_reject_candidate_world()
  local st, vals, rt = one_perform(Op.all({
    Op.emit(TC.conflict('a')),
    Op.emit(TC.conflict('b')),
  }), { quiet_deadlock = true })

  assert_uncommitted(st, 'conflicting obligations must not commit')
  assert_eq(vals.n, 0, 'participant does not resume')
  assert_eq(#rt.published_consequences, 0, 'rejected world publishes no obligations')
end

local function test_prepare_refusal_is_candidate_rejection_not_runtime_failure()
  local st, vals, rt = one_perform(Op.emit(TC.prepare_refuse()), { quiet_deadlock = true })
  assert_uncommitted(st, 'structured prepare refusal rejects the candidate')
  assert_eq(vals.n, 0, 'participant does not resume')
  assert_eq(rt:failed(), nil, 'structured refusal does not fail the runtime')

  local ok = pcall(function()
    rt:spawn_raw(function() rt:perform(Op.always('still-usable')) end, 'after-prepare-refusal')
  end)
  assert_eq(ok, true, 'runtime remains externally usable after structured refusal')
end


local function test_prepare_refusal_backtracks_to_other_worlds()
  do
    local st, vals, rt = one_perform(Op.choice(
      Op.emit(TC.prepare_refuse()):and_then(function() return Op.always('bad') end),
      Op.emit(TC.tag('fallback-choice')):and_then(function() return Op.always('good') end)
    ))
    assert_eq(st.tag, 'found')
    assert_eq(vals[1], 'good', 'choice backtracks around prepare-refused consequence world')
    assert_eq(#rt.published_consequences, 1)
    assert_eq(rt.published_consequences[1].obligation[1].payload.tag, 'fallback-choice')
  end

  do
    local st, vals, rt = one_perform(
      Op.emit(TC.prepare_refuse())
        :and_then(function() return Op.always('primary') end)
        :or_else(Op.emit(TC.tag('fallback-or-else')):and_then(function() return Op.always('fallback') end))
    )
    assert_eq(st.tag, 'found')
    assert_eq(vals[1], 'fallback', 'or_else opens fallback after prepare-refused primary has no committing world')
    assert_eq(rt.published_consequences[1].obligation[1].payload.tag, 'fallback-or-else')
  end
end

local function test_publish_failure_is_fatal_after_resource_commit()
  local cell = Cell.new(0, 'publish-fatal-cell')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(cell:write_op(1):and_then(function()
      return Op.emit(TC.publish_fatal())
    end))
  end, 'publish-fatal')

  local ok, err = pcall(function() rt:run() end)
  assert_error_kind(ok, err, 'consequence_error', 'raw publish failure is fatal consequence error')
  assert_eq(err.fatal, true)
  assert_eq(err.committed, true, 'publish failure is after resource commit')
  assert_eq(cell.value, 1, 'resource commit is not rolled back by publish failure')
  assert_eq(rt:failed(), err, 'runtime stores fatal publish failure')
end

local tests = {
  test_emit_accepts_only_typed_consequences,
  test_duplicate_obligations_merge_to_one_publication,
  test_conflicting_obligations_reject_candidate_world,
  test_prepare_refusal_is_candidate_rejection_not_runtime_failure,
  test_prepare_refusal_backtracks_to_other_worlds,
  test_publish_failure_is_fatal_after_resource_commit,
}

for i = 1, #tests do tests[i]() end
print('tests/test_consequences.lua: ok')
