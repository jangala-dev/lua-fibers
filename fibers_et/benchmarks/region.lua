package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
local fibers=require('fibers'); local n=tonumber(arg[1]) or 100
local r=fibers.Region.new('bench-region'); local hs={}
for i=1,n do hs[i]=fibers.Region.handle('h'..i) end
local t=os.clock()
fibers.run(function() for i=1,n do fibers.perform(r:admit_op(hs[i])) end end)
print(string.format('n=%d cpu=%.6f owned=%d',n,os.clock()-t,r.owned_count))
