-- Structured errors at the I/O and host boundary.
--
-- Host adapters return these values for expected failures.  Flow and Stream may
-- translate selected host conditions (notably EOF) into their own public error
-- vocabulary, but platform details remain available on the original value.

local Protected = require('fibers.protected')

local Error = {}
local ErrorMT = {}
ErrorMT.__index = ErrorMT

function ErrorMT:__tostring()
  return self.message or self.code or self.kind or 'I/O error'
end

local function copy_fields(dst, fields)
  for key, value in pairs(fields or {}) do
    dst[key] = value
  end
  return dst
end

function Error.new(kind, fields)
  if type(kind) ~= 'string' or kind == '' then
    error('I/O error kind must be a non-empty string', 2)
  end
  local out = copy_fields({
    _fibers_io_error = true,
    kind = kind,
  }, fields)
  out.message = out.message or out.code or kind
  return setmetatable(out, ErrorMT)
end

function Error.is(err, kind)
  return type(err) == 'table'
    and err._fibers_io_error == true
    and (kind == nil or err.kind == kind)
end

function Error.unsupported(domain, action, fields)
  return Error.new(
    'unsupported',
    copy_fields({
      domain = domain or 'host',
      action = action,
      code = action and ('unsupported_' .. tostring(action)) or 'unsupported',
      message = action and ('unsupported I/O action: ' .. tostring(action)) or 'unsupported I/O action',
    }, fields)
  )
end

local DEFAULTS = {
  would_block = { domain = 'io', temporary = true, message = 'I/O action would block' },
  eof = { domain = 'io', action = 'read', message = 'end of file' },
  closed = { domain = 'io', message = 'resource is closed' },
  broken_pipe = { domain = 'io', action = 'write', message = 'pipe reader is closed' },
  invalid_argument = { domain = 'host', code = 'invalid_argument', message = 'invalid I/O action argument' },
  message_too_large = {
    domain = 'datagram', action = 'send', code = 'message_too_large',
    message = 'datagram exceeds the supported message size',
  },
  truncated = {
    domain = 'datagram', action = 'receive', code = 'truncated', message = 'datagram was truncated',
  },
}
for kind, defaults in pairs(DEFAULTS) do
  Error[kind] = function(domain, action, fields)
    return Error.new(kind, copy_fields({
      domain = domain or defaults.domain,
      action = action or defaults.action,
      code = defaults.code,
      temporary = defaults.temporary,
      message = defaults.message,
    }, fields))
  end
end

function Error.system(domain, action, message, code, number, fields)
  return Error.new(
    'system',
    copy_fields({
      domain = domain or 'host',
      action = action,
      code = code,
      number = number,
      message = message or code or 'I/O system error',
    }, fields)
  )
end

function Error.protocol(domain, action, message, fields)
  return Error.new(
    'protocol',
    copy_fields({
      domain = domain or 'host',
      action = action,
      message = message or 'I/O protocol error',
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
  if err == 'broken_pipe' then
    return Error.broken_pipe(fields and fields.domain, fields and fields.action, fields)
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

function Error.capture_cleanup(errors, domain, action, fields, fn, ...)
  local called, ok, err = Protected.pcall(fn, ...)
  fields = copy_fields({ domain = domain, action = action }, fields)
  if not called then
    fields.cause = ok
    errors[#errors + 1] = Error.protocol(domain, action, 'cleanup raised', fields)
  elseif not ok then
    errors[#errors + 1] = Error.normalise(err or 'cleanup failed', fields)
  end
end

function Error.with_cleanup(primary, domain, action, message, cleanup_errors, fields)
  if #cleanup_errors == 0 then return primary end
  if primary == nil and #cleanup_errors == 1 then return cleanup_errors[1] end
  local errors = {}
  if primary ~= nil then errors[#errors + 1] = primary end
  for i = 1, #cleanup_errors do errors[#errors + 1] = cleanup_errors[i] end
  fields = fields or {}
  fields.cause, fields.errors = primary, errors
  return Error.protocol(domain, action, message, fields)
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
