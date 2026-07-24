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
local Adoption = require('fibers.region.adoption')
local Completion = require('fibers.resource.completion')

local closed = {}
local function closer(value, reason)
  closed[#closed + 1] = value .. ':' .. tostring(reason)
  return true
end

local bundle = Adoption.bundle('test-bundle')
assert(bundle:adopt('one', 'a', closer) == 'a')
assert(bundle:adopt('two', 'b', closer) == 'b')
assert(bundle:release('one', 'a') == 'a')
assert(bundle:close('done'))
assert(#closed == 1 and closed[1] == 'b:done')
assert(bundle:close('again'))

local refused = Adoption.bundle('refused')
assert(refused:adopt('item', 'first', closer))
local got, err = refused:adopt('item', 'second', closer)
assert(got == nil and err and err.kind == 'protocol')
assert(closed[#closed] == 'second:adoption refused')
assert(refused:close('cleanup'))

-- Grouped acquisition order is explicit and release_all preserves that order.
local ordered = Adoption.bundle('ordered')
local ok, ordered_err = ordered:adopt_many({
  { name = 'process', value = 'p', close = closer },
  { name = 'stdin', value = 'in', close = closer },
  { name = 'stdout', value = 'out', close = closer },
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
local rollback = Adoption.bundle('rollback')
local rollback_ok, rollback_err = rollback:adopt_many({
  { name = 'first', value = 'a', close = closer },
  { name = 'second', value = 'b', close = closer },
  { name = 'first', value = 'duplicate', close = closer },
})
assert(rollback_ok == nil and rollback_err and rollback_err.kind == 'protocol')
assert(#closed == 3)
assert(closed[1] == 'duplicate:adoption refused')
assert(closed[2] == 'b:bundle adoption rolled back')
assert(closed[3] == 'a:bundle adoption rolled back')
assert(rollback:is_empty())

local values
fibers.run(function()
  local completion = Completion.new('multi-value')
  fibers.spawn(function()
    fibers.perform(completion:publish_success_op('hello', nil, 42))
  end)
  values = { n = 3, fibers.perform(completion:result_op()) }
end)
assert(values.n == 3)
assert(values[1] == 'hello' and values[2] == nil and values[3] == 42)

local failure
fibers.run(function()
  local completion = Completion.new('failure')
  fibers.perform(completion:publish_failure_op('bad'))
  local value, completion_err = fibers.perform(completion:result_op())
  assert(value == nil)
  failure = completion_err
end)
assert(failure == 'bad')

print('tests/internal/test_adoption_completion.lua: ok')
