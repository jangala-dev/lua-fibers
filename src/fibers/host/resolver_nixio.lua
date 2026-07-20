-- Blocking Nixio getaddrinfo resolver.

local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local function unsupported(reason)
  return Provider.unsupported('fibers.host.resolver_nixio', reason, {
    'resolve',
  })
end

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then return unsupported('requires nixio') end
local Resolver = {}

local function address_from(value, service)
  if type(value) ~= 'table' then return nil end
  local family = value.family
  local host = value.address or value.addr or value.host
  local port = tonumber(value.port or value.service) or tonumber(service) or 0
  if family == 'inet' or family == 'inet4' then
    return { kind = 'inet4', family = 'inet4', host = host, port = port }
  end
  if family == 'inet6' then
    return {
      kind = 'inet6', family = 'inet6', host = host, port = port,
      flowinfo = tonumber(value.flowinfo) or 0, scope_id = tonumber(value.scope_id) or 0,
    }
  end
  return nil
end

local function key(address)
  return address.kind .. ':' .. tostring(address.host) .. ':' .. tostring(address.port)
    .. ':' .. tostring(address.scope_id or 0)
end

function Resolver.is_supported() return type(nixio.getaddrinfo) == 'function' end
function Resolver.support_reason() return Resolver.is_supported() and nil or 'Nixio getaddrinfo unavailable' end

function Resolver.resolve(_host, endpoint, opts)
  opts = opts or {}
  local requested = opts.family or endpoint.family_hint
  local family = requested == 'inet4' and 'inet' or (requested == 'inet6' and 'inet6' or 'any')
  local records, a, b = nixio.getaddrinfo(endpoint.host, family, tostring(endpoint.service))
  if records == nil then
    local eno = type(a) == 'number' and a or (type(b) == 'number' and b or nil)
    local message = type(a) == 'string' and a or (type(b) == 'string' and b or 'address resolution failed')
    return nil, HostError.system('resolver', 'resolve', tostring(message), nil, eno, { endpoint = endpoint })
  end

  local out, seen = {}, {}
  for _, record in pairs(records) do
    local address = address_from(record, endpoint.service)
    if address then
      local address_key = key(address)
      if not seen[address_key] then
        seen[address_key] = true
        out[#out + 1] = address
      end
    end
  end
  if #out == 0 then
    return nil, HostError.system(
      'resolver', 'resolve', 'name resolved to no usable stream addresses', 'EAI_NONAME', nil,
      { endpoint = endpoint }
    )
  end
  return out
end

return Resolver
