package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Protocol = require('et.protocol')

return function()
  assert(type(Protocol.Link) == 'table', 'Protocol.Link exported')
  assert(type(Protocol.Values) == 'table', 'Protocol.Values exported')
  assert(type(Protocol.Effect) == 'table', 'Protocol.Effect exported')
  assert(Protocol.Status == nil and Protocol.Result == nil, 'protocol does not export machine statuses')
  assert(Protocol.Origin == nil and Protocol.Dependency == nil, 'protocol does not export machine bookkeeping')
  print('protocol facade tests: ok')
end
