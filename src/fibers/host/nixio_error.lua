-- Nixio error and option-value conventions.

local NativeError = require('fibers.host.native_error')
local nixio = require('nixio')

local names = {}
for name, value in pairs(nixio.const or {}) do
  if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
    names[value] = names[value] or name
  end
end

return NativeError.new({
  current_errno = nixio.errno,
  strerror = nixio.strerror,
  names = names,
})
