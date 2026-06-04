package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Runtime = require('et.runtime')

return function()
  assert(type(Runtime.new) == 'function', 'Runtime.new exported')
  local rt = Runtime.new()
  assert(type(rt.spawn) == 'function', 'runtime instances expose spawn')
  assert(type(rt.perform) == 'function', 'runtime instances expose perform')
  assert(type(rt.run) == 'function', 'runtime instances expose run')
  print('runtime facade tests: ok')
end
