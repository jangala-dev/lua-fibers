-- Shared normalisation for native-binding error conventions.

local NativeError = {}

function NativeError.set(...)
  local out = {}
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if value ~= nil then
      out[value] = true
    end
  end
  return out
end

function NativeError.names(values)
  local out = {}
  for name, value in pairs(values or {}) do
    if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
      out[value] = out[value] or name
    end
  end
  return out
end

function NativeError.number(value)
  if type(value) == 'table' and type(value.fd) == 'number' then
    return value.fd
  end
  if value ~= nil and (type(value) == 'table' or type(value) == 'userdata') then
    local found, method = pcall(function()
      return value.fileno
    end)
    if found and type(method) == 'function' then
      local ok, result = pcall(method, value)
      if ok then
        return tonumber(result)
      end
    end
  end
  return tonumber(value)
end

function NativeError.new(opts)
  opts = opts or {}
  local current_errno = opts.current_errno
  local strerror = opts.strerror
  local names = opts.names or {}
  local false_is_error = opts.false_is_error == true
  local Error = {}

  function Error.current_errno()
    if type(current_errno) ~= 'function' then
      return nil
    end
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

  function Error.result(value, a, b)
    if value ~= nil and (not false_is_error or value ~= false) then return value end
    local message, number = Error.split(a, b)
    return nil, number, message
  end

  function Error.status(value, a, b)
    if value ~= nil and (not false_is_error or value ~= false) then return true end
    local message, number = Error.split(a, b)
    return nil, number, message
  end

  function Error.detail(prefix, a, b)
    local message, number = Error.split(a, b)
    if message ~= nil and message ~= '' then
      return tostring(message), number
    end
    if number ~= nil and type(strerror) == 'function' then
      local ok, value = pcall(strerror, number)
      if ok and value ~= nil and value ~= '' then
        return tostring(value), number
      end
    end
    if number ~= nil then
      return tostring(prefix) .. ' (errno ' .. tostring(number) .. ')', number
    end
    return tostring(prefix), nil
  end


  return Error
end

return NativeError
