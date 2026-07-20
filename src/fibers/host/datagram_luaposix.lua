-- Luaposix datagram-socket provider.

local HandleFd = require('fibers.host.fd_luaposix')
local HostError = require('fibers.host.error')

local ok_socket, socket = pcall(require, 'posix.sys.socket')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_errno, errno = pcall(require, 'posix.errno')

local Provider = {}

local function unsupported(reason)
  return nil, HostError.unsupported('datagram', 'open', { reason = reason })
end

function Provider.is_supported()
  return ok_socket
    and type(socket) == 'table'
    and type(socket.socket) == 'function'
    and type(socket.bind) == 'function'
    and type(socket.sendto) == 'function'
    and type(socket.recvfrom) == 'function'
    and socket.SOCK_DGRAM ~= nil
    and socket.AF_INET ~= nil
    and socket.AF_INET6 ~= nil
    and ok_unistd
    and ok_errno
    and HandleFd.is_supported()
end

local function error_value(action, message, number, fields)
  if number == errno.EAGAIN or number == (errno.EWOULDBLOCK or errno.EAGAIN) then
    return HostError.would_block('datagram', action, fields)
  end
  if errno.EMSGSIZE ~= nil and number == errno.EMSGSIZE then
    return HostError.message_too_large('datagram', action, fields)
  end
  return HostError.system('datagram', action, message, nil, number, fields)
end

local function sockaddr(address)
  if address.kind == 'inet4' then
    return { family = socket.AF_INET, addr = address.host, port = address.port }
  elseif address.kind == 'inet6' then
    return {
      family = socket.AF_INET6,
      addr = address.host,
      port = address.port,
      flowinfo = address.flowinfo or 0,
      scope_id = address.scope_id or 0,
    }
  end
  return nil, HostError.unsupported('datagram', 'address_family', { address = address })
end

local function address_from_sockaddr(sa, fallback_kind)
  if type(sa) ~= 'table' then
    return nil
  end
  if sa.family == socket.AF_INET6 or fallback_kind == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = sa.addr,
      port = tonumber(sa.port) or 0,
      flowinfo = tonumber(sa.flowinfo) or 0,
      scope_id = tonumber(sa.scope_id) or 0,
    }
  end
  return {
    kind = 'inet4',
    family = 'inet4',
    host = sa.addr,
    port = tonumber(sa.port) or 0,
  }
end

function Provider.create_datagram(host, address, opts)
  opts = opts or {}
  if not Provider.is_supported() then
    return unsupported('luaposix datagram APIs unavailable')
  end
  local bind_address, addr_err = sockaddr(address)
  if not bind_address then
    return nil, addr_err
  end
  local fd, message, number = socket.socket(bind_address.family, socket.SOCK_DGRAM, 0)
  if fd == nil then
    return nil, error_value('socket', message, number, { address = address })
  end
  local function close_raw()
    pcall(unistd.close, fd)
  end
  if opts.reuse_address == true and socket.SOL_SOCKET and socket.SO_REUSEADDR then
    local ok, set_message, set_number = socket.setsockopt(fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if ok == nil then
      close_raw()
      return nil, error_value('setsockopt_reuseaddr', set_message, set_number, { address = address })
    end
  end
  local bound, bind_message, bind_number = socket.bind(fd, bind_address)
  if bound == nil then
    close_raw()
    return nil, error_value('bind', bind_message, bind_number, { address = address })
  end
  local handle, wrap_err = HandleFd.new(fd, {
    host = host,
    name = opts.name or 'luaposix-datagram',
    nonblocking = true,
    cloexec = true,
  })
  if not handle then
    return nil, wrap_err
  end
  local local_sa = socket.getsockname(fd)
  handle.address = address_from_sockaddr(local_sa, address.kind) or address
  handle.local_address = function(self)
    return self.address
  end
  handle.recv_from = function(self, max_size)
    self:clear_readable()
    local data, peer_or_message, recv_number = socket.recvfrom(self.fd, max_size)
    if data == nil then
      return nil, error_value('receive_from', peer_or_message, recv_number, { address = self.address })
    end
    if type(data) ~= 'string' then
      return nil, HostError.protocol('datagram', 'receive_from', 'luaposix recvfrom returned non-string data')
    end
    return {
      data = data,
      peer = address_from_sockaddr(peer_or_message, address.kind),
      local_address = self.address,
      truncated = false,
      flags = {
        truncation_unknown = true,
        receive_limit = max_size,
      },
    }
  end
  handle.send_to = function(self, data, destination)
    self:clear_writable()
    local target, target_err = sockaddr(destination)
    if not target then
      return nil, target_err
    end
    local n, send_message, send_number = socket.sendto(self.fd, data, target)
    if n == nil then
      return nil, error_value('send_to', send_message, send_number, { address = destination })
    end
    return tonumber(n) or #data
  end
  return handle
end

return Provider
