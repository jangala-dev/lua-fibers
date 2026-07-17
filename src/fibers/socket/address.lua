-- Normalised socket address constructors.
--
-- Address values remain plain tables for host-adapter interoperability. The
-- constructor boundary centralises validation and family tagging.

local Address = {}

local function build(kind, fields)
  local out = {
    kind = kind,
    family = kind == 'unix' and 'unix' or 'inet',
  }
  for key, value in pairs(fields or {}) do
    out[key] = value
  end
  return out
end

function Address.inet(host, port)
  return build('inet', {
    host = host or '0.0.0.0',
    port = port or 0,
  })
end

function Address.unix(path)
  if type(path) ~= 'string' or path == '' then
    error('socket.unix_address expects a non-empty path', 2)
  end
  return build('unix', { path = path })
end

function Address.copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function Address.validate(value, label)
  if type(value) ~= 'table' then
    error((label or 'socket address') .. ' expects an address value', 3)
  end
  return Address.copy(value)
end

return Address
