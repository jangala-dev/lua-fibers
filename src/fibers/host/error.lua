-- Structured errors at the host boundary.
--
-- Host adapters return these values for expected failures.  Flow and Stream may
-- translate selected host conditions (notably EOF) into their own public error
-- vocabulary, but platform details remain available on the original value.

local Error = {}
local ErrorMT = {}
ErrorMT.__index = ErrorMT

function ErrorMT:__tostring()
  return self.message or self.code or self.kind or 'host error'
end

local function copy_fields(dst, fields)
  for key, value in pairs(fields or {}) do
    dst[key] = value
  end
  return dst
end

function Error.new(kind, fields)
  if type(kind) ~= 'string' or kind == '' then
    error('host error kind must be a non-empty string', 2)
  end
  local out = copy_fields({
    _fibers_host_error = true,
    kind = kind,
  }, fields)
  out.message = out.message or out.code or kind
  return setmetatable(out, ErrorMT)
end

function Error.is(err, kind)
  return type(err) == 'table' and err._fibers_host_error == true and (kind == nil or err.kind == kind)
end

function Error.unsupported(domain, action, fields)
  return Error.new(
    'unsupported',
    copy_fields({
      domain = domain or 'host',
      action = action,
      code = action and ('unsupported_' .. tostring(action)) or 'unsupported',
      message = action and ('unsupported host action: ' .. tostring(action)) or 'unsupported host action',
    }, fields)
  )
end

function Error.would_block(domain, action, fields)
  return Error.new(
    'would_block',
    copy_fields({
      domain = domain or 'io',
      action = action,
      temporary = true,
      message = 'host action would block',
    }, fields)
  )
end

function Error.eof(domain, action, fields)
  return Error.new(
    'eof',
    copy_fields({
      domain = domain or 'io',
      action = action or 'read',
      message = 'end of file',
    }, fields)
  )
end

function Error.closed(domain, action, fields)
  return Error.new(
    'closed',
    copy_fields({
      domain = domain or 'io',
      action = action,
      message = 'resource is closed',
    }, fields)
  )
end

function Error.system(domain, action, message, code, number, fields)
  return Error.new(
    'system',
    copy_fields({
      domain = domain or 'host',
      action = action,
      code = code,
      number = number,
      message = message or code or 'host system error',
    }, fields)
  )
end

function Error.protocol(domain, action, message, fields)
  return Error.new(
    'protocol',
    copy_fields({
      domain = domain or 'host',
      action = action,
      message = message or 'host protocol error',
    }, fields)
  )
end

function Error.normalise(err, fields)
  if Error.is(err) then
    if fields then
      for key, value in pairs(fields) do
        if err[key] == nil then
          err[key] = value
        end
      end
    end
    return err
  end
  if err == nil then
    return nil
  end
  if err == 'would_block' then
    return Error.would_block(fields and fields.domain, fields and fields.action, fields)
  end
  if err == 'eof' then
    return Error.eof(fields and fields.domain, fields and fields.action, fields)
  end
  if type(err) == 'string' then
    local action = string.match(err, '^unsupported_(.+)$')
    if action then
      return Error.unsupported(fields and fields.domain, action, fields)
    end
  end
  return Error.system(
    fields and fields.domain,
    fields and fields.action,
    tostring(err),
    fields and fields.code,
    fields and fields.number,
    fields
  )
end

function Error.is_would_block(err)
  return err == 'would_block' or Error.is(err, 'would_block')
end

function Error.is_eof(err)
  return err == 'eof' or Error.is(err, 'eof')
end

function Error.is_unsupported(err, action)
  if type(err) == 'string' then
    local got = string.match(err, '^unsupported_(.+)$')
    return got ~= nil and (action == nil or got == action)
  end
  return Error.is(err, 'unsupported') and (action == nil or err.action == action)
end

return Error
