-- Adversarial Retry-proof tests for semantic or_else fallbacks over resources.
--
-- These cases are deliberately not rendezvous-only. They make a fallback tempting
-- while causally related work can still make the preferred resource, task or Flow
-- path true. An under-recruited dependency component commits "fallback" here.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local Lifetime = require('fibers.lifetime')
local Lifetimes = require('tests.support.lifetimes')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.resource.flow')

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
  local scope = FibersScope.new():label('absence-scope-alone')
  local item = { name = 'unowned' }
  Lifetime.define(item)
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(scope:can_op(item, 'use')
      :map(function() return 'primary' end)
      :or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
  assert_eq(Lifetimes.state(item).custodian, nil)
end

-- A concurrent admission may commit before authority fallback. The authority
-- operation then observes live custody and takes the primary path.
do
  local scope = FibersScope.new():label('absence-scope-partner')
  local item = { name = 'admitted-later' }
  Lifetime.define(item)
  local got, admitted
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(scope:can_op(item, 'use')
      :map(function() return 'primary' end)
      :or_else(Op.always('fallback')))
  end):label('authority-or-fallback')
  rt:spawn_raw(function()
    admitted = rt:perform(scope:admit_op(item))
  end):label('admit-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(got, 'primary')
  assert_eq(Lifetimes.state(item).custodian, scope:lifetime())
  local record = Lifetimes.custody_snapshot(scope, item)
  assert_truthy(record and record.phase == 'live', 'admission should establish live custody')
end

-- A dormant Lifetime has no outcome and therefore permits fallback.
do
  local life = Lifetime.new({ label = 'absence-dormant' })
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
    local task = fibers.perform(scope:spawn_op(function() return 'done' end, { label = 'absence-child' }))
    got = fibers.perform(task:outcome_op():map(function(result)
      return result.ok and result.values[1] or nil
    end):or_else(Op.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'done')
end

-- With no possible producer, flow read absence may enter fallback.
do
  local flow = FibersFlow.new(8):label('absence-flow-alone')
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
  local flow = FibersFlow.new(8):label('absence-flow-writer')
  local got, n
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(flow:outlet():read_some_op(3):or_else(Op.always('fallback')))
  end):label('read-or-fallback')
  rt:spawn_raw(function()
    n = rt:perform(flow:inlet():write_op('abc'))
  end):label('write-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(n, 3)
  assert_eq(got, 'abc')
end

print('tests/test_retry_semantics.lua: ok')
