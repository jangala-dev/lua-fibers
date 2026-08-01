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
local Lifetime = require('fibers.lifetime')
local n = tonumber(arg[1]) or 100
local resources = {}
local t = os.clock()
local count
fibers.run(function(scope)
  for i = 1, n do
    local resource = { name = 'resource-' .. tostring(i) }
    Lifetime.inert(resource)
    resources[i] = resource
    fibers.perform(scope:admit_op(resource))
  end
  count = #fibers.perform(scope:children_op())
end)
print(string.format('n=%d cpu=%.6f live=%d', n, os.clock() - t, count or 0))
