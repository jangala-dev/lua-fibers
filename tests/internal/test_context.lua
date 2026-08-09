package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Context = require('fibers.internal.context')
assert(Context.runtime == nil, 'runtime context leaked between tests')

-- The direct perform boundary must remain lighter than the Runtime module.
local saved_runtime = package.loaded['fibers.runtime']
local saved_perform = package.loaded['fibers.perform']
package.loaded['fibers.runtime'] = nil
package.loaded['fibers.perform'] = nil
local perform = require('fibers.perform')
assert(type(perform) == 'function')
assert(package.loaded['fibers.runtime'] == nil, 'fibers.perform must not load the Runtime implementation')
package.loaded['fibers.perform'] = saved_perform or perform
package.loaded['fibers.runtime'] = saved_runtime


local Runtime = require('fibers.runtime')
local outer, inner = Runtime.new(), Runtime.new()
local seen = {}
outer:spawn_raw(function()
  seen[#seen + 1] = Runtime.current() == outer
  inner:spawn_raw(function()
    seen[#seen + 1] = Runtime.current() == inner
  end)
  local status = inner:run()
  while status.tag == 'found' do status = inner:run() end
  seen[#seen + 1] = Runtime.current() == outer
end)
local status = outer:run()
while status.tag == 'found' do status = outer:run() end
seen[#seen + 1] = Runtime.current() == nil
for i = 1, #seen do assert(seen[i], 'nested Runtime context restoration failed at step ' .. i) end

print('tests/internal/test_context.lua: ok')
return true
