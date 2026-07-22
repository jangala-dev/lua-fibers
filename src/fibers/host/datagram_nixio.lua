-- Nixio native datagram operations.

local DatagramCore = require('fibers.host.datagram_core')
local HostError = require('fibers.host.error')
local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return DatagramCore.define({
    prefix = 'fibers.host.datagram_nixio',
    unavailable = 'nixio module not available',
  })
end

local Fd = require('fibers.host.fd_nixio')
local NixioError = require('fibers.host.nixio_error')
local EAGAIN = nixio.const and (nixio.const.EAGAIN or nixio.const.EWOULDBLOCK) or 11
local EWOULDBLOCK = nixio.const and (nixio.const.EWOULDBLOCK or nixio.const.EAGAIN) or EAGAIN
local EMSGSIZE = nixio.const and nixio.const.EMSGSIZE or 90

local function error_value(action, a, b, fields)
  local message, number = NixioError.split(a, b)
  if number == EAGAIN or number == EWOULDBLOCK then
    return HostError.would_block('datagram', action, fields)
  end
  if number == EMSGSIZE then
    return HostError.message_too_large('datagram', action, fields)
  end
  return NixioError.system('datagram', action, message, number, fields)
end
local function encode(address)
  if address.kind == 'inet4' then
    return { family = 'inet', host = address.host, port = address.port }
  end
  if address.kind == 'inet6' then
    if (tonumber(address.scope_id) or 0) ~= 0 or (tonumber(address.flowinfo) or 0) ~= 0 then
      return nil, HostError.unsupported('datagram', 'ipv6_scope_or_flowinfo', { address = address })
    end
    return { family = 'inet6', host = address.host, port = address.port }
  end
  return nil, HostError.unsupported('datagram', 'address_family', { address = address })
end
local function decode(family, host, port)
  if family == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = host,
      port = tonumber(port) or 0,
      flowinfo = 0,
      scope_id = 0,
    }
  end
  return { kind = 'inet4', family = 'inet4', host = host, port = tonumber(port) or 0 }
end

return DatagramCore.define({
  prefix = 'fibers.host.datagram_nixio',
  name = 'nixio',
  support_reason = 'nixio datagram APIs unavailable',
  raw = function(handle)
    return handle.obj
  end,
  is_supported = function()
    return type(nixio.socket) == 'function' and Fd.is_supported()
  end,
  encode = encode,
  open = function(family, address)
    local obj, a, b = nixio.socket(family, 'dgram')
    if not obj then
      return nil, error_value('socket', a, b, { address = address })
    end
    local ok, ba, bb = obj:setblocking(false)
    if not ok then
      obj:close()
      return nil, error_value('set_nonblocking', ba, bb, { address = address })
    end
    return obj
  end,
  close_raw = function(obj)
    if obj then
      pcall(obj.close, obj)
    end
  end,
  set_reuse = function(obj, value, address)
    if type(obj.setopt) ~= 'function' then
      return true
    end
    local ok, a, b = obj:setopt('socket', 'reuseaddr', value and 1 or 0)
    if not ok then
      return nil, error_value('setsockopt_reuseaddr', a, b, { address = address })
    end
    return true
  end,
  bind = function(obj, endpoint, address)
    local ok, a, b = obj:bind(endpoint.host, endpoint.port)
    if not ok then
      return nil, error_value('bind', a, b, { address = address })
    end
    return true
  end,
  wrap = function(obj, host, name)
    return Fd.new(obj, { host = host, name = name, nonblocking = false })
  end,
  query = function(obj, family)
    local host, port = obj:getsockname()
    return decode(family, host, port)
  end,
  receive = function(obj, max_size, family, address)
    local requested = math.max(0, math.floor(tonumber(max_size) or 65535))
    local limit = math.min(requested, tonumber(nixio.const and nixio.const.buffersize) or 8192)
    local data, peer, port = obj:recvfrom(limit)
    if data == nil then
      return nil, error_value('receive_from', peer, port, { address = address })
    end
    if type(data) ~= 'string' then
      return nil, HostError.protocol('datagram', 'receive_from', 'nixio recvfrom returned non-string data')
    end
    return {
      data = data,
      peer = decode(family, peer, port),
      local_address = address,
      truncated = false,
      flags = { truncation_unknown = true, receive_limit = limit },
    }
  end,
  send = function(obj, data, endpoint, destination)
    local n, a, b = obj:sendto(data, endpoint.host, endpoint.port, 0, #data)
    if n == nil or n == false then
      return nil, error_value('send_to', a, b, { address = destination })
    end
    return n == true and #data or tonumber(n) or #data
  end,
})
