-- Runtime stepping/cursor tests.
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
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or '') .. ' expected ' .. tostring(b) .. ' got ' .. tostring(a), 2)
  end
end

-- external loop stepping
local rt = Runtime.new()
local ch = Rendezvous.new('step-ch')
local got, sent
rt:spawn_raw(function()
  got = rt:perform(ch:get_op())
end, 'r')
rt:spawn_raw(function()
  sent = rt:perform(ch:put_op('x'))
end, 's')
local seen_found = false
for i = 1, 10 do
  local st = rt:step()
  if st.tag == 'found' then
    seen_found = true
  end
  if st.tag == 'idle' then
    break
  end
end
assert_eq(seen_found, true, 'stepped commit')
assert_eq(got, 'x')
assert_eq(sent, true)

-- bounded solve should be non-mutating on budget exhaustion
local scalar = Scalar.new(0, 'budget-scalar')
local rt2 = Runtime.new()
for i = 1, 4 do
  rt2:spawn_raw(function()
    local update = scalar:read_op():and_then(function(v)
      return scalar:write_op(v + 1)
    end)
    rt2:perform(Op.never():or_else(update))
  end, 'u' .. i)
end
rt2:_pump() -- start all fibres without solving
local st = rt2:step({ max_work = 1 })
assert_eq(st.tag, 'pending', 'budget status')
assert_eq(scalar.value, 0, 'pending budget does not mutate')
local committed = false
for i = 1, 20 do
  local s = rt2:step({ max_work = 1000 })
  if s.tag == 'found' then
    committed = true
  end
  if s.tag == 'idle' or s.tag == 'quiescent' then
    break
  end
end
assert_eq(committed, true, 'eventual bounded commit')
assert_eq(scalar.value, 4)
print('tests/test_runtime.lua: step ok')

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
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or '') .. ' expected ' .. tostring(b) .. ' got ' .. tostring(a), 2)
  end
end
local function assert_truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

-- A low budget should preserve a live cursor across pending calls rather than
-- starting algebra search from scratch each tick.
local rt = Runtime.new()
local ch = Rendezvous.new('cursor-rendezvous')
local got, sent
rt:spawn_raw(function()
  got = rt:perform(ch:get_op())
end, 'r')
rt:spawn_raw(function()
  sent = rt:perform(ch:put_op('x'))
end, 's')

local saw_pending = false
local found = false
for i = 1, 20 do
  local st = rt:step({ max_work = 1 })
  if st.tag == 'pending' then
    saw_pending = true
  end
  if st.tag == 'found' then
    found = true
    break
  end
end
assert_truthy(saw_pending, 'bounded search may yield pending steps')
assert_truthy(found, 'bounded cursor eventually commits')
assert_eq(got, 'x')
assert_eq(sent, true)

-- Budget exhaustion must not mutate resources before a committable world is found.
local scalar = Scalar.new(0, 'cursor-scalar')
local rt2 = Runtime.new()
for i = 1, 4 do
  rt2:spawn_raw(function()
    rt2:perform(scalar:read_op():and_then(function(v)
      return scalar:write_op(v + 1)
    end))
  end, 'u' .. i)
end
local st = rt2:step({ max_work = 1 })
assert_eq(st.tag, 'pending')
assert_eq(scalar.value, 0, 'pending cursor step does not commit')
local commits = 0
for i = 1, 200 do
  st = rt2:step({ max_work = 3 })
  if st.tag == 'found' then
    commits = commits + 1
  end
  if st.tag == 'idle' or st.tag == 'quiescent' then
    break
  end
end
assert_eq(commits, 4)
assert_eq(scalar.value, 4)
print('tests/test_runtime.lua: cursor ok')

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
local Rendezvous = require('fibers.resource.rendezvous')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end

-- Deferred and_then continuations created before rendezvous closure must retain the
-- original evaluation context.  In particular, a guard and a residual or_else
-- inside the continuation need the fibre attempt and residual environment.
do
  local rt = Runtime.new()
  local ch = Rendezvous.new('deferred-context-search')
  local got, sent
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():and_then(function(v)
      return Op.guard(function()
        return Op.never():or_else(Op.always('fallback:' .. v))
      end)
    end))
  end, 'receiver')
  rt:spawn_raw(function()
    sent = rt:perform(ch:put_op('x'))
  end, 'sender')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(got, 'fallback:x')
  assert_eq(sent, true)
end

-- The bounded cursor exercises the same deferred path through cursor.lua.
do
  local rt = Runtime.new()
  local ch = Rendezvous.new('deferred-context-cursor')
  local got, sent, st
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():and_then(function(v)
      return Op.guard(function()
        return Op.never():or_else(Op.always('cursor-fallback:' .. v))
      end)
    end))
  end, 'receiver')
  rt:spawn_raw(function()
    sent = rt:perform(ch:put_op('y'))
  end, 'sender')
  for _ = 1, 160 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then
      break
    end
  end
  assert_status(st, 'found')
  assert_eq(got, 'cursor-fallback:y')
  assert_eq(sent, true)
end

print('tests/test_runtime.lua: deferred context ok')

print('tests/test_runtime.lua: ok')
