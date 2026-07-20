-- Blocking luaposix getaddrinfo resolver.

local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local function unsupported(reason)
  return Provider.unsupported('fibers.host.resolver_luaposix', reason, {
    'resolve',
  })
end

local ok_socket, socket = pcall(require, 'posix.sys.socket')
if not ok_socket or type(socket) ~= 'table' then
  return unsupported('requires posix.sys.socket')
end

local Resolver = {}

local function address_from(value, service)
  if type(value) ~= 'table' then
    return nil
  end
  local family = value.family
  if family == socket.AF_INET then
    return {
      kind = 'inet4',
      family = 'inet4',
      host = value.addr or value.host,
      port = tonumber(value.port) or tonumber(service) or 0,
    }
  end
  if family == socket.AF_INET6 then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = value.addr or value.host,
      port = tonumber(value.port) or tonumber(service) or 0,
      flowinfo = tonumber(value.flowinfo) or 0,
      scope_id = tonumber(value.scope_id) or 0,
    }
  end
  return nil
end

local function key(address)
  return address.kind
    .. ':'
    .. tostring(address.host)
    .. ':'
    .. tostring(address.port)
    .. ':'
    .. tostring(address.scope_id or 0)
end

function Resolver.is_supported()
  return type(socket.getaddrinfo) == 'function' and socket.SOCK_STREAM ~= nil
end

function Resolver.support_reason()
  return Resolver.is_supported() and nil or 'luaposix getaddrinfo unavailable'
end

function Resolver.resolve(_host, endpoint, opts)
  opts = opts or {}
  local family = opts.family or endpoint.family_hint
  local family_value
  if family == 'inet4' then
    family_value = socket.AF_INET
  elseif family == 'inet6' then
    family_value = socket.AF_INET6
  else
    family_value = socket.AF_UNSPEC or 0
  end

  local records, err, eno = socket.getaddrinfo(endpoint.host, tostring(endpoint.service), {
    family = family_value,
    socktype = socket.SOCK_STREAM,
  })
  if records == nil then
    return nil,
      HostError.system('resolver', 'resolve', tostring(err or 'address resolution failed'), nil, eno, {
        endpoint = endpoint,
      })
  end

  local out, seen = {}, {}
  for i = 1, #records do
    local address = address_from(records[i], endpoint.service)
    if address then
      local address_key = key(address)
      if not seen[address_key] then
        seen[address_key] = true
        out[#out + 1] = address
      end
    end
  end
  if #out == 0 then
    return nil,
      HostError.system(
        'resolver',
        'resolve',
        'name resolved to no usable stream addresses',
        'EAI_NONAME',
        nil,
        { endpoint = endpoint }
      )
  end
  return out
end

return Resolver
