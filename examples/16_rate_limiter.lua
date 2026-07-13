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

local limiter =
  fibers.RateLimiter.new({ capacity = 2, rate = 2, initial = 2, name = 'example-limiter' })

fibers.run(function()
  fibers.perform(limiter:acquire_op(1))
  fibers.perform(limiter:acquire_op(1))
  local ok, deadline = fibers.perform(limiter:try_acquire_op(1))
  assert(ok == false and deadline ~= nil)
end)

print('rate limiter example ok')
