-- Scoped stream and datagram sockets.

local Address = require('fibers.net.address')
local Listener = require('fibers.socket.listener')
local Dial = require('fibers.socket.dial')
local Datagram = require('fibers.socket.datagram')
local Resolver = require('fibers.socket.resolver')
local DNS = require('fibers.dns')
local IOError = require('fibers.io.error')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')

local Socket = {
  Listener = Listener.Listener,
  Dial = Dial.Dial,
  Query = Resolver.Query,
  DatagramSocket = Datagram.DatagramSocket,
  Error = IOError,
  DNSResolver = DNS.Resolver,

  ipv4_address = Address.ipv4,
  ipv6_address = Address.ipv6,
  name_endpoint = Address.name,
  inet_address = Address.inet,
  unix_address = Address.unix,
  address_key = Address.key,
  address_equal = Address.equal,
  format_address = Address.display,
  address_is_wildcard = Address.is_wildcard,
  address_with_port = Address.with_port,
}

function Socket.dns_resolver(opts)
  return DNS.new(opts)
end


local function numeric(address, label)
  if Address.is_name(address) then
    error(label .. ' requires a numeric IPv4 or IPv6 address', 3)
  end
  return address
end

function Socket.listen_op(address, opts)
  return Listener.listen_op(Address.validate(address, 'socket.listen_op'), opts)
end

function Socket.listen_ipv4_op(host, port, opts)
  return Listener.listen_op(Address.ipv4(host, port), opts)
end

function Socket.listen_ipv6_op(host, port, opts)
  return Listener.listen_op(Address.ipv6(host, port, opts), opts)
end

function Socket.listen_inet_op(host, port, opts)
  return Listener.listen_op(numeric(Address.inet(host, port, opts), 'socket.listen_inet_op'), opts)
end

function Socket.listen_unix_op(path, opts)
  return Listener.listen_op(Address.unix(path), opts)
end

function Socket.udp_op(address, opts)
  return Datagram.udp_op(Address.validate(address, 'socket.udp_op'), opts)
end

function Socket.udp_ipv4_op(host, port, opts)
  return Datagram.udp_op(Address.ipv4(host, port), opts)
end

function Socket.udp_ipv6_op(host, port, opts)
  return Datagram.udp_op(Address.ipv6(host, port, opts), opts)
end

function Socket.resolve_op(endpoint, opts)
  return Resolver.resolve_op(Address.validate(endpoint, 'socket.resolve_op'), opts)
end

function Socket.resolve_name_op(host, service, opts)
  return Socket.resolve_op(Address.name(host, service, opts), opts)
end

-- One Dial constructor dispatches by endpoint kind. Name endpoints select the
-- Happy Eyeballs strategy; numeric and Unix endpoints use the direct strategy.
function Socket.dial_op(endpoint, opts)
  return Dial.dial_op(Address.validate(endpoint, 'socket.dial_op'), opts)
end

Direct.install_static(Socket, {
  'listen',
  'listen_ipv4',
  'listen_ipv6',
  'listen_inet',
  'listen_unix',
  'udp',
  'udp_ipv4',
  'udp_ipv6',
  'resolve',
  'resolve_name',
  'dial',
})

function Socket.connect(endpoint, opts)
  local target = opts and opts.scope
  return perform(Socket.dial_op(endpoint, opts)):connect(target)
end


return Socket
