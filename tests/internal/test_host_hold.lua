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
local HostHold = require('fibers.io.internal.host_hold')
local Completion = require('fibers.resource.completion')

local closed = {}
local function closer(value, reason)
  closed[#closed + 1] = value .. ':' .. tostring(reason)
  return true
end

local bundle = HostHold.new():label('test-bundle')
assert(bundle:hold('one', 'a', closer) == 'a')
assert(bundle:hold('two', 'b', closer) == 'b')
assert(bundle:release('one', 'a') == 'a')
assert(bundle:close('done'))
assert(#closed == 1 and closed[1] == 'b:done')
assert(bundle:close('again'))

local refused = HostHold.new():label('refused')
assert(refused:hold('item', 'first', closer))
local got, err = refused:hold('item', 'second', closer)
assert(got == nil and err and err.kind == 'protocol')
assert(closed[#closed] == 'second:host hold refused')
assert(refused:close('cleanup'))

-- Grouped acquisition order is explicit and release_all preserves that order.
local ordered = HostHold.new():label('ordered')
local ok, ordered_err = ordered:hold_many({
  { key = 'process', value = 'p', close = closer },
  { key = 'stdin', value = 'in', close = closer },
  { key = 'stdout', value = 'out', close = closer },
})
assert(ok and ordered_err == nil)
local released = ordered:release_all()
assert(released.process == 'p')
assert(released.stdin == 'in')
assert(released.stdout == 'out')
assert(ordered:is_empty())

-- A later failure closes the refused value first, then rolls back prior
-- acquisitions in reverse declaration order.
closed = {}
local rollback = HostHold.new():label('rollback')
local rollback_ok, rollback_err = rollback:hold_many({
  { key = 'first', value = 'a', close = closer },
  { key = 'second', value = 'b', close = closer },
  { key = 'first', value = 'duplicate', close = closer },
})
assert(rollback_ok == nil and rollback_err and rollback_err.kind == 'protocol')
assert(#closed == 3)
assert(closed[1] == 'duplicate:host hold refused')
assert(closed[2] == 'b:host hold batch rolled back')
assert(closed[3] == 'a:host hold batch rolled back')
assert(rollback:is_empty())


-- HostHold cleanup is a return-value protocol even when a provider closer
-- raises.  A refusal reports the cleanup failure, and closing the hold
-- aggregates it instead of escaping the closer exception.
do
  local raising = HostHold.new():label('raising')
  local function raise_close()
    error('close exploded')
  end
  assert(raising:hold('item', 'first', raise_close))
  local refused_value, refused_err = raising:hold('item', 'second', raise_close)
  assert(refused_value == nil and refused_err and refused_err.kind == 'protocol')
  assert(refused_err.close_error and refused_err.close_error.kind == 'protocol')
  local closed_ok, closed_err = raising:close('raising cleanup')
  assert(closed_ok == nil and closed_err and closed_err.kind == 'protocol')
end

local values
fibers.run(function()
  local completion = Completion.new():label('multi-value')
  fibers.spawn(function()
    fibers.perform(completion:publish_success_op('hello', nil, 42))
  end)
  values = { n = 3, fibers.perform(completion:result_op()) }
end)
assert(values.n == 3)
assert(values[1] == 'hello' and values[2] == nil and values[3] == 42)

local failure
fibers.run(function()
  local completion = Completion.new():label('failure')
  fibers.perform(completion:publish_failure_op('bad'))
  local value, completion_err = fibers.perform(completion:result_op())
  assert(value == nil)
  failure = completion_err
end)
assert(failure == 'bad')

print('tests/internal/test_host_hold.lua: ok')
