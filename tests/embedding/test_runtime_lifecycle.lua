-- Runtime lifecycle behaviour tests.
--
-- These tests deliberately avoid inspecting runtime queues or fibre records.
-- They assert externally-observable behaviour: idle reporting, transaction
-- progress, and that completed raw fibres do not remain reachable merely
-- because the Runtime is long-lived.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Op = require('fibers.op')
local Rendezvous = require('fibers.resource.rendezvous')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function collect()
  for _ = 1, 4 do
    collectgarbage('collect')
  end
end

local function drive(rt, limit)
  limit = limit or 100
  local saw_found = false
  local last
  for _ = 1, limit do
    last = rt:run()
    if last.tag == 'found' then
      saw_found = true
    end
    if last.tag == 'idle' or last.tag == 'quiescent' or last.tag == 'pending' then
      return saw_found, last
    end
  end
  fail('runtime did not quiesce')
end

-- Empty and drained runtimes report idle rather than absence.
do
  local rt = Runtime.new()
  local st = rt:run()
  assert_eq(st.tag, 'idle', 'empty runtime run() is idle')

  local ran = false
  rt:spawn_raw(function()
    ran = rt:perform(Op.always(true))
  end):label('one-shot')

  local found, last = drive(rt)
  assert_truthy(found, 'runtime should commit the one-shot fibre')
  assert_eq(ran, true)
  assert_eq(last.tag, 'idle', 'drained runtime is idle')
end

-- Completed raw fibres do not stay alive through the Runtime.  The test keeps
-- the Runtime object and drops all other strong references to per-fibre marker
-- tables.  If the Runtime archives completed fibre stacks, the weak entries
-- will remain live.
do
  local rt = Runtime.new()
  local weak = setmetatable({}, { __mode = 'v' })
  for i = 1, 40 do
    local marker = { i = i }
    weak[i] = marker
    rt:spawn_raw(function()
      rt:perform(Op.always(true))
      return marker
    end):label('short-' .. tostring(i))
    marker = nil
  end

  local found, last = drive(rt)
  assert_truthy(found, 'short fibres should commit')
  assert_eq(last.tag, 'idle', 'runtime should drain after short fibres')
  collect()
  for i = 1, 40 do
    assert_eq(weak[i], nil, 'completed fibre marker should be collectable')
  end
end

-- Waiting and rendezvous behaviour is tested through Rendezvous communication,
-- not by inspecting the runtime's waiting frontier.
do
  local rt = Runtime.new()
  local ch = Rendezvous.new():label('frontier-rendezvous')
  local got
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op())
  end):label('receiver')
  local st = rt:run()
  assert_eq(st.tag, 'quiescent', 'receiver has no compatible transaction until a sender arrives')

  rt:spawn_raw(function()
    rt:perform(ch:put_op('x'))
  end):label('sender')
  local found, last = drive(rt)
  assert_truthy(found, 'sender and receiver should rendezvous')
  assert_eq(got, 'x')
  assert_eq(last.tag, 'idle', 'runtime idles after rendezvous')
end

print('tests/test_runtime_lifecycle.lua: ok')
