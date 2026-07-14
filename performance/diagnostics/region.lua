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
local Region = require('fibers.lifetime.region')
local n = tonumber(arg[1]) or 100
local r = Region.new('bench-region')
local hs = {}
for i = 1, n do
  hs[i] = Region.handle('h' .. i)
end
local t = os.clock()
fibers.run(function()
  for i = 1, n do
    fibers.perform(r:admit_op(hs[i]))
  end
end)
print(string.format('n=%d cpu=%.6f owned=%d', n, os.clock() - t, r.owned_count))
