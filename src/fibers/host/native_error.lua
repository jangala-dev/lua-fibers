-- Shared normalisation for native-provider error conventions.

local HostError = require('fibers.host.error')

local NativeError = {}

function NativeError.new(opts)
  opts = opts or {}
  local current_errno = opts.current_errno
  local strerror = opts.strerror
  local names = opts.names or {}
  local Error = {}

  function Error.current_errno()
    if type(current_errno) ~= 'function' then return nil end
    local ok, value = pcall(current_errno)
    return ok and tonumber(value) or nil
  end

  function Error.split(a, b)
    local message, number
    if type(a) == 'number' then
      number, message = a, b
    elseif type(b) == 'number' then
      number, message = b, a
    else
      message = a or b
    end
    number = tonumber(number) or Error.current_errno()
    return message, number
  end

  function Error.name(number)
    return number ~= nil and names[number] or nil
  end

  function Error.message(prefix, a, b)
    local message, number = Error.split(a, b)
    if message ~= nil and message ~= '' then return tostring(message), number end
    local detail
    if number ~= nil and type(strerror) == 'function' then
      local ok, value = pcall(strerror, number)
      if ok and value ~= nil and value ~= '' then detail = tostring(value) end
    end
    if detail then return tostring(prefix) .. ': ' .. detail, number end
    if number ~= nil then return tostring(prefix) .. ' (errno ' .. tostring(number) .. ')', number end
    return tostring(prefix), nil
  end

  function Error.detail(prefix, a, b)
    local message, number = Error.split(a, b)
    if message ~= nil and message ~= '' then return tostring(message), number end
    if number ~= nil and type(strerror) == 'function' then
      local ok, value = pcall(strerror, number)
      if ok and value ~= nil and value ~= '' then return tostring(value), number end
    end
    if number ~= nil then return tostring(prefix) .. ' (errno ' .. tostring(number) .. ')', number end
    return tostring(prefix), nil
  end

  function Error.system(domain, action, a, b, fields)
    local message, number = Error.message(tostring(action) .. ' failed', a, b)
    return HostError.system(domain, action, message, Error.name(number), number, fields)
  end

  function Error.option(value)
    if type(value) == 'boolean' then return value and 1 or 0 end
    return value
  end

  return Error
end

return NativeError
