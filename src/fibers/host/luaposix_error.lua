-- Luaposix error and option-value conventions.

local NativeError = require('fibers.host.native_error')
local errno = require('posix.errno')

local names = {}
for name, value in pairs(errno) do
  if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
    names[value] = names[value] or name
  end
end

return NativeError.new({ names = names })
