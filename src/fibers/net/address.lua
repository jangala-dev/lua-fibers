-- Immutable-by-convention socket address and endpoint constructors.
--
-- Numeric addresses are explicit IPv4, IPv6, or Unix values. Host names are
-- unresolved endpoints and must pass through fibers.socket.resolve before a
-- native listener or DialAttempt can use them.

local Contract = require('fibers.internal.contract')

local Address = {}

local function port_number(port, label)
  if type(port) ~= 'number' or port ~= port or port < 0 or port > 65535 or port ~= math.floor(port) then
    error((label or 'socket address') .. ' expects an integer port from 0 to 65535', 3)
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
    host = nonempty(host == nil and '0.0.0.0' or host, 'socket.ipv4_address'),
    port = port_number(port == nil and 0 or port, 'socket.ipv4_address'),
  })
end

function Address.ipv6(host, port, opts)
  opts = Contract.options(opts, { flowinfo = true, scope_id = true }, 'socket.ipv6_address options', 2)
  local flowinfo = opts.flowinfo == nil and 0
    or Contract.non_negative_integer(opts.flowinfo, 'socket.ipv6_address flowinfo', 2)
  local scope_id = opts.scope_id == nil and 0
    or Contract.non_negative_integer(opts.scope_id, 'socket.ipv6_address scope_id', 2)
  return build('inet6', {
    host = nonempty(host == nil and '::' or host, 'socket.ipv6_address'),
    port = port_number(port == nil and 0 or port, 'socket.ipv6_address'),
    flowinfo = flowinfo,
    scope_id = scope_id,
  })
end

function Address.unix(path)
  return build('unix', { path = nonempty(path, 'socket.unix_address') })
end

-- Native Unix-domain address queries may report an unnamed endpoint. Public
-- listen and dial addresses remain strict, while decoders use nil to mean that
-- the operating system did not provide a usable pathname.
function Address.decode_unix(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  return Address.unix(path)
end

function Address.name(host, service, opts)
  opts = Contract.options(opts, { family_hint = true, socket_type = true }, 'socket.name_endpoint options', 2)
  if service == nil then
    error('socket.name_endpoint expects a service or port', 2)
  end
  if type(service) ~= 'string' and type(service) ~= 'number' then
    error('socket.name_endpoint service must be a string or integer port', 2)
  end
  if type(service) == 'string' then nonempty(service, 'socket.name_endpoint service')
  else port_number(service, 'socket.name_endpoint service') end
  if opts.family_hint ~= nil and opts.family_hint ~= 'unspec' and opts.family_hint ~= 'inet4' and opts.family_hint ~= 'inet6' then
    error("socket.name_endpoint family_hint must be 'unspec', 'inet4', 'inet6' or nil", 2)
  end
  if opts.socket_type ~= nil and opts.socket_type ~= 'stream' and opts.socket_type ~= 'datagram' then
    error("socket.name_endpoint socket_type must be 'stream', 'datagram' or nil", 2)
  end
  return build('name', {
    host = nonempty(host, 'socket.name_endpoint'),
    service = service,
    family_hint = opts.family_hint,
    socket_type = opts.socket_type or 'stream',
  })
end

function Address.inet(host, port, opts)
  host = host == nil and '0.0.0.0' or host
  nonempty(host, 'socket.inet_address')
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
  return Contract.copy_table(value, 'socket address copy source', 2)
end

function Address.is_numeric(value)
  return type(value) == 'table' and (value.kind == 'inet4' or value.kind == 'inet6' or value.kind == 'unix')
end

function Address.is_name(value)
  return type(value) == 'table' and value.kind == 'name'
end

local function key(value)
  if value.kind == 'unix' then return 'unix:' .. value.path end
  if value.kind == 'inet6' then
    return 'inet6:[' .. value.host .. ']:' .. tostring(value.port) .. ':' .. tostring(value.scope_id or 0)
  end
  if value.kind == 'inet4' then return 'inet4:' .. value.host .. ':' .. tostring(value.port) end
  return 'name:' .. value.host .. ':' .. tostring(value.service)
end

function Address.key(value) return key(Address.validate(value, 'socket address')) end

function Address.validate(value, label)
  label = label or 'socket address'
  if type(value) ~= 'table' then
    error(label .. ' expects an address value', 3)
  end
  if type(value.kind) ~= 'string' then
    error(label .. ' requires a canonical kind field', 3)
  end
  if value.family ~= nil and value.family ~= value.kind then
    error(label .. ' kind and family fields disagree', 3)
  end
  if value.kind == 'inet4' then
    return Address.ipv4(value.host, value.port)
  end
  if value.kind == 'inet6' then
    return Address.ipv6(value.host, value.port, { flowinfo = value.flowinfo, scope_id = value.scope_id })
  end
  if value.kind == 'unix' then
    return Address.unix(value.path)
  end
  if value.kind == 'name' then
    return Address.name(value.host, value.service, {
      family_hint = value.family_hint,
      socket_type = value.socket_type,
    })
  end
  error(label .. ' has unknown address kind ' .. tostring(value.kind), 3)
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
  return key(aa) == key(bb)
end

function Address.display(value)
  value = Address.validate(value, 'socket address')
  if value.kind == 'unix' then
    return value.path
  elseif value.kind == 'inet6' then
    local scope = value.scope_id
    local host = value.host .. (scope ~= 0 and ('%' .. tostring(scope)) or '')
    return '[' .. host .. ']:' .. tostring(value.port)
  elseif value.kind == 'inet4' then
    return value.host .. ':' .. tostring(value.port)
  end
  return tostring(value.host) .. ':' .. tostring(value.service)
end

function Address.is_wildcard(value)
  value = Address.validate(value, 'socket address')
  return (value.kind == 'inet4' and value.host == '0.0.0.0') or (value.kind == 'inet6' and value.host == '::')
end

function Address.with_port(value, port)
  value = Address.validate(value, 'socket address')
  if value.kind == 'unix' then
    error('Unix socket addresses do not have ports', 2)
  end
  if value.kind == 'name' then value.service = port
  else value.port = port_number(port, 'socket address') end
  return value
end

return Address
