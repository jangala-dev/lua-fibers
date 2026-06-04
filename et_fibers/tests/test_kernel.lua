package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Kernel = require('et.kernel')

return function()
  assert(type(Kernel.Status.found) == 'function', 'kernel exposes Status.found')
  assert(type(Kernel.Status.stale) == 'function', 'kernel exposes Status.stale')
  assert(type(Kernel.Phase.with) == 'function', 'kernel exposes Phase.with')
  assert(type(Kernel.Util.pack) == 'function', 'kernel exposes Util.pack')
  assert(Kernel.Origin == nil, 'kernel does not own Origin')
  assert(Kernel.Dependency == nil, 'kernel does not own Dependency')
  assert(Kernel.Consequence == nil, 'kernel does not own Consequence')
  print('kernel tests: ok')
end
