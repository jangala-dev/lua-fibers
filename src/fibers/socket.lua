-- Scoped stream sockets.
--
-- This public facade contains address constructors and the practical Listener
-- and Dial entry points. Their implementations live in focused submodules.

local Address = require('fibers.socket.address')
local ListenerModule = require('fibers.socket.listener')
local DialModule = require('fibers.socket.dial')
local DatagramModule = require('fibers.socket.datagram')
local ResolverModule = require('fibers.socket.resolver')
local HostError = require('fibers.host.error')
local IO = require('fibers.internal.io')
local perform = require('fibers.perform')

local Socket = {
  Listener = ListenerModule.Listener,
  Dial = DialModule.Dial,
  Query = ResolverModule.Query,
  DatagramSocket = DatagramModule.DatagramSocket,
  Error = HostError,
}

function Socket.ipv4_address(host, port)
  return Address.ipv4(host, port)
end

function Socket.ipv6_address(host, port, opts)
  return Address.ipv6(host, port, opts)
end

function Socket.name_endpoint(host, service, opts)
  return Address.name(host, service, opts)
end

function Socket.inet_address(host, port, opts)
  return Address.inet(host, port, opts)
end

function Socket.unix_address(path)
  return Address.unix(path)
end

Socket.address_key = Address.key
Socket.address_equal = Address.equal
Socket.format_address = Address.display
Socket.address_is_wildcard = Address.is_wildcard
Socket.address_with_port = Address.with_port

function Socket.listen_op(address, opts)
  return ListenerModule.listen_op(Address.validate(address, 'socket.listen_op'), opts)
end

function Socket.listen_ipv4_op(host, port, opts)
  return ListenerModule.listen_op(Address.ipv4(host, port), opts)
end

function Socket.listen_ipv6_op(host, port, opts)
  return ListenerModule.listen_op(Address.ipv6(host, port, opts), opts)
end

function Socket.listen_inet_op(host, port, opts)
  local address = Address.inet(host, port, opts)
  if Address.is_name(address) then
    error('socket.listen_inet_op requires a numeric IPv4 or IPv6 address', 2)
  end
  return ListenerModule.listen_op(address, opts)
end

function Socket.listen_unix_op(path, opts)
  return ListenerModule.listen_op(Address.unix(path), opts)
end

function Socket.udp_op(address, opts)
  return DatagramModule.udp_op(Address.validate(address, 'socket.udp_op'), opts)
end

function Socket.udp_ipv4_op(host, port, opts)
  return DatagramModule.udp_op(Address.ipv4(host, port), opts)
end

function Socket.udp_ipv6_op(host, port, opts)
  return DatagramModule.udp_op(Address.ipv6(host, port, opts), opts)
end

function Socket.resolve_op(endpoint, opts)
  return ResolverModule.resolve_op(Address.validate(endpoint, 'socket.resolve_op'), opts)
end

function Socket.resolve_name_op(host, service, opts)
  return ResolverModule.resolve_op(Address.name(host, service, opts), opts)
end

function Socket.dial_op(address, opts)
  return DialModule.dial_op(Address.validate(address, 'socket.dial_op'), opts)
end

function Socket.dial_ipv4_op(host, port, opts)
  opts = IO.copy_table(opts)
  if opts.bind_host ~= nil or opts.bind_port ~= nil then
    opts.local_address = Address.ipv4(opts.bind_host or '0.0.0.0', opts.bind_port or 0)
  end
  return DialModule.dial_op(Address.ipv4(host, port), opts)
end

function Socket.dial_ipv6_op(host, port, opts)
  opts = IO.copy_table(opts)
  if opts.bind_host ~= nil or opts.bind_port ~= nil then
    opts.local_address = Address.ipv6(opts.bind_host or '::', opts.bind_port or 0, opts)
  end
  return DialModule.dial_op(Address.ipv6(host, port, opts), opts)
end

function Socket.dial_inet_op(host, port, opts)
  opts = IO.copy_table(opts)
  if opts.bind_host ~= nil or opts.bind_port ~= nil then
    opts.local_address = Address.inet(opts.bind_host or '0.0.0.0', opts.bind_port or 0)
  end
  local address = Address.inet(host, port, opts)
  if Address.is_name(address) then
    error('socket.dial_inet_op requires a resolved IPv4 or IPv6 address; use socket.resolve first', 2)
  end
  return DialModule.dial_op(address, opts)
end

function Socket.dial_unix_op(path, opts)
  return DialModule.dial_op(Address.unix(path), opts)
end

function Socket.listen(address, opts) return perform(Socket.listen_op(address, opts)) end

function Socket.listen_ipv4(host, port, opts) return perform(Socket.listen_ipv4_op(host, port, opts)) end

function Socket.listen_ipv6(host, port, opts) return perform(Socket.listen_ipv6_op(host, port, opts)) end

function Socket.listen_inet(host, port, opts) return perform(Socket.listen_inet_op(host, port, opts)) end

function Socket.listen_unix(path, opts) return perform(Socket.listen_unix_op(path, opts)) end

function Socket.udp(address, opts) return perform(Socket.udp_op(address, opts)) end

function Socket.udp_ipv4(host, port, opts) return perform(Socket.udp_ipv4_op(host, port, opts)) end

function Socket.udp_ipv6(host, port, opts) return perform(Socket.udp_ipv6_op(host, port, opts)) end


function Socket.resolve(endpoint, opts) return perform(Socket.resolve_op(endpoint, opts)) end

function Socket.resolve_name(host, service, opts) return perform(Socket.resolve_name_op(host, service, opts)) end

function Socket.dial(address, opts) return perform(Socket.dial_op(address, opts)) end

function Socket.dial_ipv4(host, port, opts) return perform(Socket.dial_ipv4_op(host, port, opts)) end

function Socket.dial_ipv6(host, port, opts) return perform(Socket.dial_ipv6_op(host, port, opts)) end

function Socket.dial_inet(host, port, opts) return perform(Socket.dial_inet_op(host, port, opts)) end

function Socket.dial_unix(path, opts) return perform(Socket.dial_unix_op(path, opts)) end

return Socket
