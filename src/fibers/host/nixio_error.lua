-- Nixio error and option-value conventions.

local NativeError = require('fibers.host.native_error')
local nixio = require('nixio')

local names = {}
for name, value in pairs(nixio.const or {}) do
  if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
    names[value] = names[value] or name
  end
end

local Error = NativeError.new({
  current_errno = nixio.errno,
  strerror = nixio.strerror,
  names = names,
})

-- Nixio uses nil with no explicit error for EOF and not-ready waitpid results
-- on some Lua/ABI combinations.  Some builds also return the strerror(0) text
-- "Success" while errno still contains an unrelated earlier value.  Treat the
-- explicit return values as authoritative instead of promoting stale errno.
function Error.no_error(a, b)
  if a == nil and b == nil then
    return true, nil, nil
  end
  local message, number = Error.split(a, b)
  if number == nil or number == 0 then
    return true, message, number
  end
  if type(message) == 'string' and message:match('^%s*[Ss]uccess%s*$') then
    return true, message, number
  end
  return false, message, number
end

return Error
