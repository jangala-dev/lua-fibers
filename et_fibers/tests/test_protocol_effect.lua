package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Effect = require('et.protocol').Effect

return function()
  assert(Effect.wake('r', 'k').tag == 'wake', 'Effect.wake constructor')
  assert(Effect.publish('topic', 'value').tag == 'publish', 'Effect.publish constructor')
  assert(Effect.resource('settlement', 'key', { reason = 'x' }).tag == 'settlement', 'Effect.resource constructor')
  print('protocol/effect tests: ok')
end
