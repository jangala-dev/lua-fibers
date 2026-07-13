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
local Runtime = require('fibers.kernel.runtime')
local Op = require('fibers.atoms.op')

local depth = 512
local op = Op.always('done')
for _ = 1, depth do
  op = Op.never():or_else(op)
end

local rt = Runtime.new({ plan_reuse = false })
local got
rt:spawn_raw(function()
  got = rt:perform(op)
end, 'deep-explicit-stack')
local status = rt:run()
assert(status.tag == 'found', 'deep explicit-stack search should commit')
rt:run()
assert(got == 'done', 'deep explicit-stack search should preserve fallback result')
assert(
  (rt.stats.search_calls or 0) >= depth,
  'deep explicit-stack search should traverse the requested alternatives'
)

print('tests/test_search_stack.lua: ok')
