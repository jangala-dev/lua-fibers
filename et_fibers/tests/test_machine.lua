package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Machine = require('et.machine')

return function()
  assert(type(Machine.Frontier) == 'table', 'Machine.Frontier exported')
  assert(type(Machine.ProofNet) == 'table', 'Machine.ProofNet exported')
  assert(type(Machine.World) == 'table', 'Machine.World exported')
  assert(type(Machine.Commit) == 'table', 'Machine.Commit exported')
  assert(Machine.Kernel == nil and Machine.Attempt == nil, 'machine facade does not export compatibility aliases')
  assert(Machine.Result == nil and Machine.Protocol == nil, 'machine facade does not leak aliases')
  print('machine facade tests: ok')
end
