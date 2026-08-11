package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
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
    Lifetime.define(resource)
    resources[i] = resource
    fibers.perform(scope:admit_op(resource))
  end
  count = 0
  for i = 1, #resources do
    if fibers.perform(scope:has_custody_op(resources[i])) then count = count + 1 end
  end
end)
print(string.format('n=%d cpu=%.6f live=%d', n, os.clock() - t, count or 0))
