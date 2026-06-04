package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Values = require('et.protocol').Values

return function()
  local row = Values.pack('a', nil, 'c')
  local a, b, c = Values.unpack(row)
  assert(a == 'a' and b == nil and c == 'c', 'Values preserves nil-bearing rows')
  print('protocol/values tests: ok')
end
