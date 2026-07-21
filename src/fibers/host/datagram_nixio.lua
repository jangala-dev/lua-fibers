-- Nixio datagram-socket provider.
--
-- Only numeric IPv4 and IPv6 addresses enter this provider.  Nixio's bind and
-- sendto helpers may internally call getaddrinfo, but numeric input prevents
-- Fibers from hiding hostname-resolution policy inside a datagram action.

local Fd = require('fibers.host.fd_nixio')
local HostError = require('fibers.host.error')

local ok_nixio, nixio = pcall(require, 'nixio')
local Provider = {}
local NixioError = ok_nixio and require('fibers.host.nixio_error') or nil

local EAGAIN = ok_nixio and nixio.const and (nixio.const.EAGAIN or nixio.const.EWOULDBLOCK) or 11
local EWOULDBLOCK = ok_nixio and nixio.const and (nixio.const.EWOULDBLOCK or nixio.const.EAGAIN) or EAGAIN
local EMSGSIZE = ok_nixio and nixio.const and nixio.const.EMSGSIZE or 90

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

function Provider.is_supported()
  return ok_nixio and type(nixio) == 'table' and type(nixio.socket) == 'function' and Fd.is_supported()
end

local function nixio_address(address)
  if address.kind == 'inet4' then
    return 'inet', address.host, address.port
  elseif address.kind == 'inet6' then
    if (tonumber(address.scope_id) or 0) ~= 0 or (tonumber(address.flowinfo) or 0) ~= 0 then
      return nil,
        nil,
        nil,
        HostError.unsupported('datagram', 'ipv6_scope_or_flowinfo', {
          address = address,
        })
    end
    return 'inet6', address.host, address.port
  end
  return nil, nil, nil, HostError.unsupported('datagram', 'address_family', { address = address })
end

local function address_value(kind, host, port)
  if kind == 'inet6' then
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

function Provider.create_datagram(host, address, opts)
  opts = opts or {}
  if not Provider.is_supported() then
    return nil, HostError.unsupported('datagram', 'open', { reason = 'nixio datagram APIs unavailable' })
  end
  local family, bind_host, bind_port, address_err = nixio_address(address)
  if not family then
    return nil, address_err
  end

  local object, socket_a, socket_b = nixio.socket(family, 'dgram')
  if not object then
    return nil, error_value('socket', socket_a, socket_b, { address = address })
  end
  local function close_raw()
    pcall(function()
      object:close()
    end)
  end

  local nonblocking, block_a, block_b = object:setblocking(false)
  if not nonblocking then
    close_raw()
    return nil, error_value('set_nonblocking', block_a, block_b, { address = address })
  end
  if opts.reuse_address == true and type(object.setopt) == 'function' then
    local set, set_a, set_b = object:setopt('socket', 'reuseaddr', 1)
    if not set then
      close_raw()
      return nil, error_value('setsockopt_reuseaddr', set_a, set_b, { address = address })
    end
  end
  local bound, bind_a, bind_b = object:bind(bind_host, bind_port)
  if not bound then
    close_raw()
    return nil, error_value('bind', bind_a, bind_b, { address = address })
  end

  local handle, wrap_err = Fd.new(object, {
    host = host,
    name = opts.name or 'nixio-datagram',
    nonblocking = false,
  })
  if not handle then
    return nil, wrap_err
  end
  local local_host, local_port = object:getsockname()
  handle.address = address_value(family, local_host or bind_host, local_port or bind_port)
  handle.local_address = function(self)
    return self.address
  end
  handle.recv_from = function(self, max_size)
    self:clear_readable()
    local requested = math.max(0, math.floor(tonumber(max_size) or 65535))
    local buffer_limit = tonumber(nixio.const and nixio.const.buffersize) or 8192
    local receive_limit = math.min(requested, buffer_limit)
    local data, peer_or_message, port_or_number = self.obj:recvfrom(receive_limit)
    if data == nil then
      return nil, error_value('receive_from', peer_or_message, port_or_number, { address = self.address })
    end
    if type(data) ~= 'string' then
      return nil, HostError.protocol('datagram', 'receive_from', 'nixio recvfrom returned non-string data')
    end
    return {
      data = data,
      peer = address_value(family, peer_or_message, port_or_number),
      local_address = self.address,
      truncated = false,
      flags = {
        truncation_unknown = true,
        receive_limit = receive_limit,
      },
    }
  end
  handle.send_to = function(self, data, destination)
    self:clear_writable()
    local target_family, target_host, target_port, target_err = nixio_address(destination)
    if not target_family then
      return nil, target_err
    end
    if target_family ~= family then
      return nil,
        HostError.protocol('datagram', 'send_to', 'source and destination address families differ', {
          source = self.address,
          destination = destination,
        })
    end
    local n, send_a, send_b = self.obj:sendto(data, target_host, target_port, 0, #data)
    if n == nil or n == false then
      return nil, error_value('send_to', send_a, send_b, { address = destination })
    end
    if n == true then
      return #data
    end
    return tonumber(n) or #data
  end
  return handle
end

return Provider
