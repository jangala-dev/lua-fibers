-- Typed effect obligation protocol tests.

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
local TC = require('tests.support.effect_helpers')

local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end

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
local function assert_error_kind(ok, err, kind, msg)
  if ok then
    fail((msg or 'expected error') .. ': call succeeded')
  end
  if type(err) ~= 'table' or err.kind ~= kind then
    fail(
      (msg or 'wrong error kind')
        .. ': expected '
        .. tostring(kind)
        .. ', got '
        .. tostring(type(err) == 'table' and err.kind or err)
    )
  end
end
local function assert_uncommitted(st, msg)
  local tag = st and st.tag
  if tag ~= 'quiescent' and tag ~= 'pending' and tag ~= 'reject_candidate' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local vals = { n = 0 }
  rt:spawn_raw(function()
    vals = pack_(rt:perform(op))
  end, 'one-perform')
  return rt:run(), vals, rt
end

local function test_emit_accepts_only_typed_effects()
  local ok, err = pcall(function()
    return Op.emit({ tag = 'raw' })
  end)
  assert_eq(ok, false, 'raw emit should fail')
  assert_truthy(tostring(err):match('typed effect'), 'raw emit error explains expectation')
end

local function test_duplicate_obligations_merge_to_one_discharge()
  local calls = {}
  local rt = Runtime.new({
    host = {
      test_tag = function(tag)
        calls[#calls + 1] = tag
      end,
    },
  })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.all({
      Op.emit(TC.tag('dup')),
      Op.emit(TC.tag('dup')),
    }))
  end, 'duplicate-effect')

  local st = rt:run()
  assert_eq(st.tag, 'found')
  assert_truthy(got, 'participant resumed')
  assert_eq(#calls, 1, 'duplicate same-key obligations discharge once')
  assert_eq(calls[1], 'dup')
end

local function test_conflicting_obligations_reject_candidate_world()
  local st, vals, rt = one_perform(
    Op.all({
      Op.emit(TC.conflict('a')),
      Op.emit(TC.conflict('b')),
    }),
    { quiet_deadlock = true }
  )

  assert_uncommitted(st, 'conflicting obligations must not commit')
  assert_eq(vals.n, 0, 'participant does not resume')
end

local function test_prepare_refusal_is_candidate_rejection_not_runtime_failure()
  local st, vals, rt = one_perform(Op.emit(TC.prepare_refuse()), { quiet_deadlock = true })
  assert_uncommitted(st, 'structured prepare refusal rejects the candidate')
  assert_eq(vals.n, 0, 'participant does not resume')
  assert_eq(rt:failed(), nil, 'structured refusal does not fail the runtime')

  local ok = pcall(function()
    rt:spawn_raw(function()
      rt:perform(Op.always('still-usable'))
    end, 'after-prepare-refusal')
  end)
  assert_eq(ok, true, 'runtime remains externally usable after structured refusal')
end

local function test_prepare_refusal_backtracks_to_other_worlds()
  do
    local calls = {}
    local st, vals = one_perform(
      Op.choice(
        Op.emit(TC.prepare_refuse()):and_then(function()
          return Op.always('bad')
        end),
        Op.emit(TC.tag('fallback-choice')):and_then(function()
          return Op.always('good')
        end)
      ),
      {
        host = {
          test_tag = function(tag)
            calls[#calls + 1] = tag
          end,
        },
      }
    )
    assert_eq(st.tag, 'found')
    assert_eq(vals[1], 'good', 'choice backtracks around prepare-refused effect world')
    assert_eq(table.concat(calls, ','), 'fallback-choice')
  end

  do
    local calls = {}
    local st, vals = one_perform(
      Op.emit(TC.prepare_refuse())
        :and_then(function()
          return Op.always('primary')
        end)
        :or_else(Op.emit(TC.tag('fallback-or-else')):and_then(function()
          return Op.always('fallback')
        end)),
      {
        host = {
          test_tag = function(tag)
            calls[#calls + 1] = tag
          end,
        },
      }
    )
    assert_eq(st.tag, 'found')
    assert_eq(
      vals[1],
      'fallback',
      'or_else opens fallback after prepare-refused primary has no committing world'
    )
    assert_eq(table.concat(calls, ','), 'fallback-or-else')
  end
end

local function test_discharge_failure_is_fatal_after_resource_commit()
  local scalar = Scalar.new(0, 'discharge-fatal-scalar')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(scalar:write_op(1):and_then(function()
      return Op.emit(TC.discharge_fatal())
    end))
  end, 'discharge-fatal')

  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'effect_error', 'raw discharge failure is fatal effect error')
  assert_eq(err.fatal, true)
  assert_eq(err.committed, true, 'discharge failure is after resource commit')
  assert_eq(scalar.value, 1, 'resource commit is not rolled back by discharge failure')
  assert_eq(rt:failed(), err, 'runtime stores fatal discharge failure')
end

local tests = {
  test_emit_accepts_only_typed_effects,
  test_duplicate_obligations_merge_to_one_discharge,
  test_conflicting_obligations_reject_candidate_world,
  test_prepare_refusal_is_candidate_rejection_not_runtime_failure,
  test_prepare_refusal_backtracks_to_other_worlds,
  test_discharge_failure_is_fatal_after_resource_commit,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/test_effects.lua: ok')
