-- Scoped stream sockets.
--
-- This public facade contains address constructors and the practical Listener
-- and Dial entry points. Their implementations live in focused submodules.

local Address = require('fibers.socket.address')
local ListenerModule = require('fibers.socket.listener')
local DialModule = require('fibers.socket.dial')
local HostError = require('fibers.host.error')
local IO = require('fibers.internal.io')
local perform = require('fibers.perform')

local Socket = {
  Listener = ListenerModule.Listener,
  Dial = DialModule.Dial,
  Error = HostError,
}

function Socket.inet_address(host, port)
  return Address.inet(host, port)
end

function Socket.unix_address(path)
  return Address.unix(path)
end

function Socket.listen_op(address, opts)
  return ListenerModule.listen_op(Address.validate(address, 'socket.listen_op'), opts)
end

function Socket.listen_inet_op(host, port, opts)
  return ListenerModule.listen_op(Address.inet(host, port), opts)
end

function Socket.listen_unix_op(path, opts)
  return ListenerModule.listen_op(Address.unix(path), opts)
end

function Socket.dial_op(address, opts)
  return DialModule.dial_op(Address.validate(address, 'socket.dial_op'), opts)
end

function Socket.dial_inet_op(host, port, opts)
  opts = IO.copy_table(opts)
  if opts.bind_host ~= nil or opts.bind_port ~= nil then
    opts.local_address = Address.inet(opts.bind_host or '0.0.0.0', opts.bind_port or 0)
  end
  return DialModule.dial_op(Address.inet(host, port), opts)
end

function Socket.dial_unix_op(path, opts)
  return DialModule.dial_op(Address.unix(path), opts)
end

function Socket.listen(address, opts)
  return perform(Socket.listen_op(address, opts))
end

function Socket.listen_inet(host, port, opts)
  return perform(Socket.listen_inet_op(host, port, opts))
end

function Socket.listen_unix(path, opts)
  return perform(Socket.listen_unix_op(path, opts))
end

function Socket.dial(address, opts)
  return perform(Socket.dial_op(address, opts))
end

function Socket.dial_inet(host, port, opts)
  return perform(Socket.dial_inet_op(host, port, opts))
end

function Socket.dial_unix(path, opts)
  return perform(Socket.dial_unix_op(path, opts))
end

return Socket
