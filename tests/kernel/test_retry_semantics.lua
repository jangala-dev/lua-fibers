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
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.lifetime.region')
local FibersFlow = require('fibers.flow')
local FibersTask = require('fibers.task')

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

-- With no possible owner transition, region claim absence may enter fallback.
do
  local region = FibersRegion.new('absence-region-alone')
  local item = FibersRegion.handle('unowned')
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(region
      :claim_op(item)
      :map(function()
        return 'primary'
      end)
      :or_else(fibers.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
  assert_eq(item.owner, nil)
end

-- A concurrent admission must be allowed to commit before the claim fallback.
-- The claim then observes the committed owner fact and takes the primary path.
do
  local region = FibersRegion.new('absence-region-partner')
  local item = FibersRegion.handle('admitted-later')
  local got, admitted
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(region
      :claim_op(item)
      :map(function()
        return 'primary'
      end)
      :or_else(fibers.always('fallback')))
  end, 'claim-or-fallback')
  rt:spawn_raw(function()
    admitted = rt:perform(region:admit_op(item))
  end, 'admit-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(admitted, item)
  assert_eq(got, 'primary')
  assert_eq(item.owner, region)
  assert_truthy(
    region.owned[item] and region.owned[item].phase == 'claimed',
    'claim should own the committed item'
  )
end

-- A never-started task really is absent to an await fallback.
do
  local task = FibersTask.new(function()
    return 'unused'
  end, 'absence-never-started')
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(task:await_op():or_else(fibers.always('fallback')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'fallback')
end

-- A start option and the child fibre must be given a chance to run before
-- the await fallback can commit.
do
  local region = FibersRegion.new('absence-task-region')
  local task = FibersTask.new(function()
    return 'done'
  end, 'absence-child')
  local got, started
  local rt = FibersRuntime.new()
  rt:spawn_raw(function()
    got = rt:perform(task:await_op():or_else(fibers.always('fallback')))
  end, 'await-or-fallback')
  rt:spawn_raw(function()
    started = rt:perform(task:start_op(region))
  end, 'start-child')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(started, task)
  assert_eq(got, 'done')
end

-- With no possible producer, flow read absence may enter fallback.
do
  local flow = FibersFlow.new({ name = 'absence-flow-alone', capacity = 8 })
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(flow:outlet():read_some_op(3):or_else(fibers.always('fallback')))
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
    got = rt:perform(flow:outlet():read_some_op(3):or_else(fibers.always('fallback')))
  end, 'read-or-fallback')
  rt:spawn_raw(function()
    n = rt:perform(flow:inlet():write_op('abc'))
  end, 'write-partner')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(n, 3)
  assert_eq(got, 'abc')
end

print('tests/test_retry_semantics.lua: ok')
