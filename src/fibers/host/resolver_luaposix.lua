-- Luaposix resolver for the atomic luaposix family.

local Family = require('fibers.host.family')
local HostError = require('fibers.host.error')
local Resolver = require('fibers.host.resolver')
local ok, socket = pcall(require, 'posix.sys.socket')
if not ok or type(socket) ~= 'table' then
  return Family.unsupported('fibers.host.resolver_luaposix', 'requires posix.sys.socket', { 'resolve' })
end

return Resolver.define({
  reason = 'luaposix getaddrinfo unavailable',
  is_supported = function()
    return type(socket.getaddrinfo) == 'function' and socket.SOCK_STREAM ~= nil
  end,
  query = function(endpoint, opts)
    local requested = opts.family or endpoint.family_hint
    local family = requested == 'inet4' and socket.AF_INET
      or requested == 'inet6' and socket.AF_INET6
      or socket.AF_UNSPEC
      or 0
    local records, err, eno = socket.getaddrinfo(endpoint.host, tostring(endpoint.service), {
      family = family,
      socktype = socket.SOCK_STREAM,
    })
    if records then
      return records
    end
    return nil,
      HostError.system('resolver', 'resolve', tostring(err or 'address resolution failed'), nil, eno, {
        endpoint = endpoint,
      })
  end,
  records = ipairs,
  address = function(value, service)
    if type(value) ~= 'table' then
      return nil
    end
    if value.family == socket.AF_INET then
      return {
        kind = 'inet4',
        family = 'inet4',
        host = value.addr or value.host,
        port = tonumber(value.port) or tonumber(service) or 0,
      }
    end
    if value.family == socket.AF_INET6 then
      return {
        kind = 'inet6',
        family = 'inet6',
        host = value.addr or value.host,
        port = tonumber(value.port) or tonumber(service) or 0,
        flowinfo = tonumber(value.flowinfo) or 0,
        scope_id = tonumber(value.scope_id) or 0,
      }
    end
  end,
})
