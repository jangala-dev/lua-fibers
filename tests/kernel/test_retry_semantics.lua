-- Adversarial Retry-proof tests for semantic or_else fallbacks over resources.
--
-- These cases are deliberately not rendezvous-only.  They make a fallback tempting
-- while another root can still make the preferred resource/task/flow path true
-- by committing first.  A too-local or_else commits "fallback" in these tests.

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

local fibers = require('fibers')
local Op = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local Lifetime = require('fibers.lifetime')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.resource.flow')
local Certificate = require('fibers.internal.kernel.certificate')

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
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

-- With no possible custody or Grant transition, authority absence may enter
-- fallback.
do
  local scope = FibersScope.new('absence-scope-alone')
  local item = { name = 'unowned' }
  Lifetime.inert(item)
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(scope
      :can_op(item, 'use')
      :map(function()
        return 'primary'
      end)
      :or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
  assert_eq(Lifetime.of(item):current_state().custodian, nil)
end

-- A concurrent admission may commit before authority fallback. The authority
-- operation then observes live custody and takes the primary path.
do
  local scope = FibersScope.new('absence-scope-partner')
  local item = { name = 'admitted-later' }
  Lifetime.inert(item)
  local got, admitted
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(scope
      :can_op(item, 'use')
      :map(function()
        return 'primary'
      end)
      :or_else(Op.always('fallback')))
  end, 'authority-or-fallback')
  rt:spawn_raw(function()
    admitted = rt:perform(scope:admit_op(item))
  end, 'admit-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(got, 'primary')
  assert_eq(Lifetime.of(item):current_state().custodian, scope:lifetime())
  local record
  rt:spawn_raw(function()
    record = rt:perform(scope:custody_op(item))
  end, 'inspect-custody')
  rt:run()
  assert_truthy(record and record.phase == 'live', 'admission should establish live custody')
end

-- A dormant running Lifetime has no outcome and therefore permits fallback.
do
  local life = Lifetime.task(function()
    return 'unused'
  end, { name = 'absence-dormant-running' })
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(life:outcome_op():or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
end

-- Once a task admission commits, its scheduled body must be allowed to produce
-- the Lifetime outcome before an await fallback is accepted.
do
  local got
  local st = fibers.try_run(function(scope)
    local task = fibers.perform(scope:spawn_op(function()
      return 'done'
    end, { name = 'absence-child' }))
    got = fibers.perform(task:await_op():or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'done')
end

-- With no possible producer, flow read absence may enter fallback.
do
  local flow = FibersFlow.new({ name = 'absence-flow-alone', capacity = 8 })
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(flow:outlet():read_some_op(3):or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
end

-- A concurrent writer must not be masked by the reader fallback.  The writer
-- commits first; the reader then observes bytes and takes the primary path.
do
  local flow = FibersFlow.new({ name = 'absence-flow-writer', capacity = 8 })
  local got, n
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(flow:outlet():read_some_op(3):or_else(Op.always('fallback')))
  end, 'read-or-fallback')
  rt:spawn_raw(function()
    n = rt:perform(flow:inlet():write_op('abc'))
  end, 'write-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(n, 3)
  assert_eq(got, 'abc')
end

-- Branch-local absence is promoted explicitly before runtime retention or
-- revalidation.  Mixing durable and local facts remains local until capture.
do
  local rt = FibersRuntime.new()
  local local_proof = Certificate.from_intents({})
  assert_truthy(Certificate.is_local(local_proof), 'terminal absence should remain branch-local')
  local valid, reason = Certificate.valid(local_proof, rt)
  assert_eq(valid, false)
  assert_eq(reason, 'local-absence')

  local durable =
    assert(Certificate.capture(rt, {}, { ids = {}, dependencies = {}, dynamic = 0 }, local_proof))
  assert_truthy(Certificate.is_durable(durable), 'runtime capture should produce a durable retry certificate')
  assert_eq(Certificate.valid(durable, rt), true)

  local mixed = Certificate.merge(Certificate.copy(durable), local_proof)
  assert_truthy(Certificate.is_local(mixed), 'mixed proof facts must remain local until recaptured')
end

print('tests/test_retry_semantics.lua: ok')
