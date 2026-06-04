package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')

return function()
  local a = Op.always('x')
  assert(a and a.tag == 'always', 'Op.always constructs inert syntax')
  assert(Op.never().tag == 'never', 'Op.never constructs inert syntax')
  assert(a:map(function(x) return x end).tag == 'map', 'Op.map constructs inert syntax')
  assert(a:and_then(function() return Op.always(true) end).tag == 'bind', 'Op.and_then constructs inert syntax')
  assert(Op.choice(Op.never(), a).tag == 'choice', 'Op.choice constructs inert syntax')
  assert(Op.tensor({ a }).tag == 'tensor', 'Op.tensor constructs inert syntax')
  assert(Op.all({ a }).tag == 'all', 'Op.all constructs inert syntax')
  local wrapped = a:wrap(function(x) return x end)
  assert(wrapped.tag == 'wrap' and require('et.op').is_boundary(wrapped), 'Op.wrap constructs a continuation boundary')
  local ok = pcall(function() return wrapped:and_then(function() return a end) end)
  assert(not ok, 'wrap boundary rejects transactional sequencing')
  print('op tests: ok')
end
