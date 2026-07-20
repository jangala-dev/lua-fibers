-- Immutable-by-convention socket address and endpoint constructors.
--
-- Numeric addresses are explicit IPv4, IPv6, or Unix values. Host names are
-- unresolved endpoints and must pass through fibers.socket.resolve before a
-- native listener or DialAttempt can use them.

local Address = {}

local function port_number(port, label)
  port = tonumber(port)
  if not port or port < 0 or port > 65535 or port ~= math.floor(port) then
    error((label or 'socket address') .. ' expects a port from 0 to 65535', 3)
  end
  return port
end

local function nonempty(value, label)
  if type(value) ~= 'string' or value == '' then
    error((label or 'socket address') .. ' expects a non-empty string', 3)
  end
  return value
end

local function build(kind, fields)
  local out = { kind = kind, family = kind }
  for key, value in pairs(fields or {}) do
    out[key] = value
  end
  return out
end

function Address.ipv4(host, port)
  return build('inet4', {
    host = nonempty(host or '0.0.0.0', 'socket.ipv4_address'),
    port = port_number(port or 0, 'socket.ipv4_address'),
  })
end

function Address.ipv6(host, port, opts)
  opts = opts or {}
  return build('inet6', {
    host = nonempty(host or '::', 'socket.ipv6_address'),
    port = port_number(port or 0, 'socket.ipv6_address'),
    flowinfo = tonumber(opts.flowinfo) or 0,
    scope_id = tonumber(opts.scope_id) or 0,
  })
end

function Address.unix(path)
  return build('unix', { path = nonempty(path, 'socket.unix_address') })
end

function Address.name(host, service, opts)
  opts = opts or {}
  if service == nil then
    error('socket.name_endpoint expects a service or port', 2)
  end
  return build('name', {
    host = nonempty(host, 'socket.name_endpoint'),
    service = service,
    family_hint = opts.family_hint or (opts.family ~= 'name' and opts.family or nil),
    socket_type = opts.socket_type or 'stream',
  })
end

function Address.inet(host, port, opts)
  host = host or '0.0.0.0'
  if string.find(host, ':', 1, true) then
    return Address.ipv6(host, port, opts)
  end
  if host:match('^%d+%.%d+%.%d+%.%d+$') then
    return Address.ipv4(host, port)
  end
  if host == '*' then
    return Address.ipv4('0.0.0.0', port)
  end
  return Address.name(host, port, opts)
end

function Address.copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function Address.is_numeric(value)
  return type(value) == 'table'
    and (value.kind == 'inet4' or value.kind == 'inet6' or value.kind == 'unix')
end

function Address.is_name(value)
  return type(value) == 'table' and value.kind == 'name'
end

function Address.key(value)
  value = Address.validate(value, 'socket address')
  if value.kind == 'unix' then
    return 'unix:' .. value.path
  elseif value.kind == 'inet6' then
    return 'inet6:[' .. value.host .. ']:' .. tostring(value.port) .. ':' .. tostring(value.scope_id or 0)
  elseif value.kind == 'inet4' then
    return 'inet4:' .. value.host .. ':' .. tostring(value.port)
  end
  return 'name:' .. value.host .. ':' .. tostring(value.service)
end

function Address.validate(value, label)
  label = label or 'socket address'
  if type(value) ~= 'table' then
    error(label .. ' expects an address value', 3)
  end
  if value.kind == 'inet4' or value.family == 'inet4' then
    return Address.ipv4(value.host, value.port)
  end
  if value.kind == 'inet6' or value.family == 'inet6' then
    return Address.ipv6(value.host, value.port, value)
  end
  if value.kind == 'unix' or value.family == 'unix' then
    return Address.unix(value.path)
  end
  if value.kind == 'name' or value.family == 'name' then
    return Address.name(value.host, value.service or value.port, value)
  end
  error(label .. ' has unknown address kind ' .. tostring(value.kind or value.family), 3)
end

function Address.equal(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then
    return false
  end
  local ok_a, aa = pcall(Address.validate, a, 'left socket address')
  local ok_b, bb = pcall(Address.validate, b, 'right socket address')
  if not ok_a or not ok_b then
    return false
  end
  return Address.key(aa) == Address.key(bb)
end

function Address.display(value)
  value = Address.validate(value, 'socket address')
  if value.kind == 'unix' then
    return value.path
  elseif value.kind == 'inet6' then
    local scope = tonumber(value.scope_id) or 0
    local host = value.host .. (scope ~= 0 and ('%' .. tostring(scope)) or '')
    return '[' .. host .. ']:' .. tostring(value.port)
  elseif value.kind == 'inet4' then
    return value.host .. ':' .. tostring(value.port)
  end
  return tostring(value.host) .. ':' .. tostring(value.service)
end

function Address.is_wildcard(value)
  value = Address.validate(value, 'socket address')
  return (value.kind == 'inet4' and value.host == '0.0.0.0')
    or (value.kind == 'inet6' and value.host == '::')
end

function Address.with_port(value, port)
  value = Address.validate(value, 'socket address')
  if value.kind == 'unix' then
    error('Unix socket addresses do not have ports', 2)
  end
  local out = Address.copy(value)
  if out.kind == 'name' then
    out.service = port
  else
    out.port = port_number(port, 'socket address')
  end
  return Address.validate(out, 'socket address')
end

return Address
