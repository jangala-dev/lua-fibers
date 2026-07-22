-- LuaPosix native datagram operations.

local DatagramCore = require('fibers.host.datagram_core')
local HostError = require('fibers.host.error')
local ok_socket, socket = pcall(require, 'posix.sys.socket')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_errno, errno = pcall(require, 'posix.errno')
if not ok_socket or type(socket) ~= 'table' or not ok_unistd or not ok_errno then
  return DatagramCore.define({
    prefix = 'fibers.host.datagram_luaposix',
    unavailable = 'luaposix datagram APIs unavailable',
  })
end

local Fd = require('fibers.host.fd_luaposix')
local PosixError = require('fibers.host.luaposix_error')
local EAGAIN = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or EAGAIN

local function error_value(action, message, number, fields)
  if number == EAGAIN or number == EWOULDBLOCK then
    return HostError.would_block('datagram', action, fields)
  end
  if errno.EMSGSIZE ~= nil and number == errno.EMSGSIZE then
    return HostError.message_too_large('datagram', action, fields)
  end
  return PosixError.system('datagram', action, message, number, fields)
end
local function encode(address)
  if address.kind == 'inet4' then
    return {
      family = socket.AF_INET,
      native = { family = socket.AF_INET, addr = address.host, port = address.port },
    }
  elseif address.kind == 'inet6' then
    return {
      family = socket.AF_INET6,
      native = {
        family = socket.AF_INET6,
        addr = address.host,
        port = address.port,
        flowinfo = address.flowinfo or 0,
        scope_id = address.scope_id or 0,
      },
    }
  end
  return nil, HostError.unsupported('datagram', 'address_family', { address = address })
end
local function decode(sa, family)
  if type(sa) ~= 'table' then
    return nil
  end
  if sa.family == socket.AF_INET6 or family == socket.AF_INET6 then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = sa.addr,
      port = tonumber(sa.port) or 0,
      flowinfo = tonumber(sa.flowinfo) or 0,
      scope_id = tonumber(sa.scope_id) or 0,
    }
  end
  return { kind = 'inet4', family = 'inet4', host = sa.addr, port = tonumber(sa.port) or 0 }
end

return DatagramCore.define({
  prefix = 'fibers.host.datagram_luaposix',
  name = 'luaposix',
  support_reason = 'luaposix datagram APIs unavailable',
  is_supported = function()
    return type(socket.socket) == 'function'
      and type(socket.bind) == 'function'
      and type(socket.sendto) == 'function'
      and type(socket.recvfrom) == 'function'
      and socket.SOCK_DGRAM ~= nil
      and Fd.is_supported()
  end,
  encode = encode,
  open = function(family, address)
    local fd, message, number = socket.socket(family, socket.SOCK_DGRAM, 0)
    if fd == nil then
      return nil, error_value('socket', message, number, { address = address })
    end
    return fd
  end,
  close_raw = function(fd)
    pcall(unistd.close, fd)
  end,
  set_reuse = function(fd, value, address)
    if not socket.SOL_SOCKET or not socket.SO_REUSEADDR then
      return true
    end
    local ok, message, number =
      socket.setsockopt(fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, value and 1 or 0)
    if ok == nil then
      return nil, error_value('setsockopt_reuseaddr', message, number, { address = address })
    end
    return true
  end,
  bind = function(fd, endpoint, address)
    local ok, message, number = socket.bind(fd, endpoint.native)
    if ok == nil then
      return nil, error_value('bind', message, number, { address = address })
    end
    return true
  end,
  wrap = function(fd, host, name)
    return Fd.new(fd, { host = host, name = name, nonblocking = true, cloexec = true })
  end,
  query = function(fd, family)
    return decode(socket.getsockname(fd), family)
  end,
  receive = function(fd, max_size, family, address)
    local data, peer, number = socket.recvfrom(fd, max_size)
    if data == nil then
      return nil, error_value('receive_from', peer, number, { address = address })
    end
    if type(data) ~= 'string' then
      return nil, HostError.protocol('datagram', 'receive_from', 'luaposix recvfrom returned non-string data')
    end
    return {
      data = data,
      peer = decode(peer, family),
      local_address = address,
      truncated = false,
      flags = { truncation_unknown = true, receive_limit = max_size },
    }
  end,
  send = function(fd, data, endpoint, destination)
    local n, message, number = socket.sendto(fd, data, endpoint.native)
    if n == nil then
      return nil, error_value('send_to', message, number, { address = destination })
    end
    return tonumber(n) or #data
  end,
})
