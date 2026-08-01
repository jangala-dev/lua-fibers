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
local Runtime = require('fibers.runtime')
local Op = require('fibers.op')

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

local depth = 512
local op = Op.always('done')
for _ = 1, depth do
  op = Op.never():or_else(op)
end

local rt = Runtime.new({ instrumentation = true })
local got
rt:spawn_raw(function()
  got = rt:perform(op)
end, 'deep-explicit-stack')
local status = rt:run()
assert(status.tag == 'found', 'deep explicit-stack search should commit')
rt:run()
assert(got == 'done', 'deep explicit-stack search should preserve fallback result')
assert(
  (counter(rt, 'search_calls') or 0) >= depth,
  'deep explicit-stack search should traverse the requested alternatives'
)

print('tests/test_search_stack.lua: ok')
