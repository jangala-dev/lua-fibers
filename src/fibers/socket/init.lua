-- Scoped stream and datagram sockets.

local Address = require('fibers.net.address')
local Listener = require('fibers.socket.listener')
local Dial = require('fibers.socket.dial')
local Datagram = require('fibers.socket.datagram')
local Resolver = require('fibers.socket.resolver')
local DNSResolver = require('fibers.dns.resolver')
local IOError = require('fibers.io.error')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Contract = require('fibers.internal.contract')

local function address_options(opts)
  if type(opts) ~= 'table' then return nil end
  return { flowinfo = opts.flowinfo, scope_id = opts.scope_id }
end

local function operation_options(opts)
  if type(opts) ~= 'table' then return opts end
  local out = {}
  for key, value in pairs(opts) do
    if key ~= 'flowinfo' and key ~= 'scope_id' then out[key] = value end
  end
  return out
end

local Socket = {
  Listener = Listener.Listener,
  Dial = Dial.Dial,
  Query = Resolver.Query,
  DatagramSocket = Datagram.DatagramSocket,
  Error = IOError,
  DNSResolver = DNSResolver,

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

Socket.dns_resolver = DNSResolver.new


local function numeric(address, label)
  if Address.is_name(address) then
    error(label .. ' requires a numeric IPv4 or IPv6 address', 3)
  end
  return address
end

Socket.submit_listen_op = Listener.submit_listen_op
Socket.listen = Listener.listen

function Socket.submit_listen_ipv4_op(host, port, opts)
  return Listener.submit_listen_op(Address.ipv4(host, port), opts)
end

function Socket.listen_ipv4(host, port, opts)
  return Listener.listen(Address.ipv4(host, port), opts)
end

function Socket.submit_listen_ipv6_op(host, port, opts)
  return Listener.submit_listen_op(Address.ipv6(host, port, address_options(opts)), operation_options(opts))
end

function Socket.listen_ipv6(host, port, opts)
  return Listener.listen(Address.ipv6(host, port, address_options(opts)), operation_options(opts))
end

function Socket.submit_listen_inet_op(host, port, opts)
  return Listener.submit_listen_op(
    numeric(Address.inet(host, port, address_options(opts)), 'socket.submit_listen_inet_op'),
    operation_options(opts)
  )
end

function Socket.listen_inet(host, port, opts)
  return Listener.listen(
    numeric(Address.inet(host, port, address_options(opts)), 'socket.listen_inet'),
    operation_options(opts)
  )
end

function Socket.submit_listen_unix_op(path, opts)
  return Listener.submit_listen_op(Address.unix(path), opts)
end

function Socket.listen_unix(path, opts)
  return Listener.listen(Address.unix(path), opts)
end

Socket.submit_udp_op = Datagram.submit_udp_op
Socket.udp = Datagram.udp

function Socket.submit_udp_ipv4_op(host, port, opts)
  return Datagram.submit_udp_op(Address.ipv4(host, port), opts)
end

function Socket.udp_ipv4(host, port, opts)
  return Datagram.udp(Address.ipv4(host, port), opts)
end

function Socket.submit_udp_ipv6_op(host, port, opts)
  return Datagram.submit_udp_op(Address.ipv6(host, port, address_options(opts)), operation_options(opts))
end

function Socket.udp_ipv6(host, port, opts)
  return Datagram.udp(Address.ipv6(host, port, address_options(opts)), operation_options(opts))
end

Socket.resolve_op = Resolver.resolve_op

function Socket.resolve_name_op(host, service, opts)
  if opts == nil then return Socket.resolve_op(Address.name(host, service)) end
  local resolve_opts = Contract.copy_table(opts, 'socket.resolve_name options', 3)
  if resolve_opts.family_hint ~= nil and resolve_opts.family ~= nil then
    error('socket.resolve_name options must not specify both family_hint and family', 3)
  end
  local endpoint = Address.name(host, service, {
    family_hint = resolve_opts.family_hint or resolve_opts.family, socket_type = resolve_opts.socket_type,
  })
  resolve_opts.family_hint, resolve_opts.socket_type = nil, nil
  return Socket.resolve_op(endpoint, resolve_opts)
end

-- One Dial constructor dispatches by endpoint kind. Name endpoints select the
-- Happy Eyeballs strategy; numeric and Unix endpoints use the direct strategy.
Socket.dial_op = Dial.dial_op

Direct.install_static(Socket, {
  'submit_listen',
  'submit_listen_ipv4',
  'submit_listen_ipv6',
  'submit_listen_inet',
  'submit_listen_unix',
  'submit_udp',
  'submit_udp_ipv4',
  'submit_udp_ipv6',
  'resolve',
  'resolve_name',
  'dial',
})

function Socket.connect(endpoint, opts)
  local target = type(opts) == 'table' and opts.scope or nil
  return perform(Socket.dial_op(endpoint, opts)):connect(target)
end


return Socket
