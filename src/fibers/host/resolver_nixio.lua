-- Nixio resolver for the atomic nixio family.

local Family = require('fibers.host.family')
local HostError = require('fibers.host.error')
local Resolver = require('fibers.host.resolver')
local ok, nixio = pcall(require, 'nixio')
if not ok or type(nixio) ~= 'table' then
  return Family.unsupported('fibers.host.resolver_nixio', 'requires nixio', { 'resolve' })
end

return Resolver.define({
  reason = 'Nixio getaddrinfo unavailable',
  is_supported = function()
    return type(nixio.getaddrinfo) == 'function'
  end,
  query = function(endpoint, opts)
    local requested = opts.family or endpoint.family_hint
    local family = requested == 'inet4' and 'inet' or requested == 'inet6' and 'inet6' or 'any'
    local records, a, b = nixio.getaddrinfo(endpoint.host, family, tostring(endpoint.service))
    if records then
      return records
    end
    local eno = type(a) == 'number' and a or type(b) == 'number' and b or nil
    local message = type(a) == 'string' and a or type(b) == 'string' and b or 'address resolution failed'
    return nil, HostError.system('resolver', 'resolve', tostring(message), nil, eno, { endpoint = endpoint })
  end,
  records = pairs,
  address = function(value, service)
    if type(value) ~= 'table' then
      return nil
    end
    local host = value.address or value.addr or value.host
    local port = tonumber(value.port or value.service) or tonumber(service) or 0
    if value.family == 'inet' or value.family == 'inet4' then
      return { kind = 'inet4', family = 'inet4', host = host, port = port }
    end
    if value.family == 'inet6' then
      return {
        kind = 'inet6',
        family = 'inet6',
        host = host,
        port = port,
        flowinfo = tonumber(value.flowinfo) or 0,
        scope_id = tonumber(value.scope_id) or 0,
      }
    end
  end,
})
