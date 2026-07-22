-- LuaPosix native stream-socket operations.

local HostError = require('fibers.host.error')
local SocketCore = require('fibers.host.socket_core')

local ok_socket, socket = pcall(require, 'posix.sys.socket')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_errno, errno = pcall(require, 'posix.errno')
if
  not ok_socket
  or type(socket) ~= 'table'
  or not ok_unistd
  or type(unistd) ~= 'table'
  or not ok_errno
  or type(errno) ~= 'table'
then
  return SocketCore.define({
    prefix = 'fibers.host.socket_luaposix',
    unavailable = 'requires posix.sys.socket, posix.unistd and posix.errno',
  })
end

local Fd = require('fibers.host.fd_luaposix')
local PosixError = require('fibers.host.luaposix_error')
local AF = { inet4 = socket.AF_INET, inet6 = socket.AF_INET6, unix = socket.AF_UNIX }
local EAGAIN, EINTR = errno.EAGAIN, errno.EINTR
local EWOULDBLOCK = errno.EWOULDBLOCK or EAGAIN
local pending = {
  [errno.EINPROGRESS] = true,
  [errno.EALREADY] = true,
  [EAGAIN] = true,
  [EWOULDBLOCK] = true,
}
local connected = { [errno.EISCONN] = true }
local support_cache = {}

local function system_error(action, err, eno, fields)
  return PosixError.system('socket', action, err, eno, fields)
end

local function encode(address)
  local kind = address and (address.kind or address.family)
  local family = AF[kind]
  if family == nil then
    local action = kind == 'inet4' and 'ipv4'
      or kind == 'inet6' and 'ipv6'
      or kind == 'unix' and 'unix'
      or 'address'
    return nil,
      (kind and HostError.unsupported or HostError.invalid_argument)('socket', action, { address = address })
  end
  if kind == 'unix' then
    return { family = family, native = { family = family, path = address.path } }
  end
  return {
    family = family,
    native = {
      family = family,
      addr = address.host,
      port = tonumber(address.port),
      flowinfo = kind == 'inet6' and (tonumber(address.flowinfo) or 0) or nil,
      scope_id = kind == 'inet6' and (tonumber(address.scope_id) or 0) or nil,
    },
  }
end

local function decode(value, family)
  if type(value) ~= 'table' then
    return nil
  end
  family = value.family or family
  if family == AF.inet4 or family == 'inet' or family == 'inet4' then
    return {
      kind = 'inet4',
      family = 'inet4',
      host = value.addr or value.host,
      port = tonumber(value.port) or 0,
    }
  elseif family == AF.inet6 or family == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = value.addr or value.host,
      port = tonumber(value.port) or 0,
      flowinfo = tonumber(value.flowinfo) or 0,
      scope_id = tonumber(value.scope_id) or 0,
    }
  elseif family == AF.unix or family == 'unix' then
    return { kind = 'unix', family = 'unix', path = value.path or value.addr or value.host }
  end
end

local function set_option(fd, level, option, value, action, fields)
  if level == nil or option == nil or type(socket.setsockopt) ~= 'function' then
    return nil, HostError.unsupported('socket', action, fields)
  end
  local ok, err, eno = socket.setsockopt(fd, level, option, PosixError.option(value))
  if ok == nil then
    return nil, system_error(action, err, eno, fields)
  end
  return true
end

local function supported(family)
  if family == nil or not Fd.is_supported() or socket.SOCK_STREAM == nil then
    return false
  end
  if support_cache[family] == nil then
    local fd = socket.socket(family, socket.SOCK_STREAM, 0)
    support_cache[family] = fd ~= nil
    if fd ~= nil then
      pcall(unistd.close, fd)
    end
  end
  return support_cache[family]
end

return SocketCore.define({
  prefix = 'fibers.host.socket_luaposix',
  name = 'luaposix',
  handle_family = 'numeric-socket',
  support_reason = 'required luaposix stream socket functions unavailable',
  supports = function(kind)
    return supported(AF[kind] or kind)
  end,
  encode = encode,
  is_unix = function(family)
    return family == AF.unix
  end,
  unlink = function(path)
    if path and type(unistd.unlink) == 'function' then
      pcall(unistd.unlink, path)
    end
  end,
  open = function(family)
    local fd, err, eno = socket.socket(family, socket.SOCK_STREAM, 0)
    if fd == nil then
      return nil, system_error('socket', err, eno)
    end
    return fd
  end,
  close_raw = function(fd)
    if fd ~= nil then
      pcall(unistd.close, fd)
    end
  end,
  wrap = function(fd, host, name)
    return Fd.new(fd, { host = host, name = name, nonblocking = true, cloexec = true })
  end,
  query = function(fd, peer, family)
    return decode(peer and socket.getpeername(fd) or socket.getsockname(fd), family)
  end,
  decode_peer = decode,
  set_reuse = function(fd, value, address)
    return set_option(
      fd,
      socket.SOL_SOCKET,
      socket.SO_REUSEADDR,
      value,
      'setsockopt_reuseaddr',
      { address = address }
    )
  end,
  set_nodelay = function(fd, value, address)
    return set_option(
      fd,
      socket.IPPROTO_TCP,
      socket.TCP_NODELAY,
      value,
      'setsockopt_nodelay',
      { address = address }
    )
  end,
  bind = function(fd, endpoint, address)
    local ok, err, eno = socket.bind(fd, endpoint.native)
    if ok == nil then
      return nil, system_error('bind', err, eno, { address = address })
    end
    return true
  end,
  listen = function(fd, backlog, address)
    local ok, err, eno = socket.listen(fd, backlog)
    if ok == nil then
      return nil, system_error('listen', err, eno, { address = address })
    end
    return true
  end,
  accept = function(fd, address)
    while true do
      local child, peer, eno = socket.accept(fd)
      if child ~= nil then
        return child, peer
      end
      if eno == EINTR then
      elseif eno == EAGAIN or eno == EWOULDBLOCK then
        return nil, nil, HostError.would_block('socket', 'accept', { address = address })
      else
        return nil, nil, system_error('accept', peer, eno, { address = address })
      end
    end
  end,
  connect = function(fd, endpoint, address)
    local ok, err, eno = socket.connect(fd, endpoint.native)
    if ok ~= nil or connected[eno] then
      return 'connected'
    end
    if pending[eno] then
      return 'pending'
    end
    return nil, system_error('connect', err, eno, { address = address })
  end,
  finish_connect = function(fd, _endpoint, address)
    local value, err, eno = socket.getsockopt(fd, socket.SOL_SOCKET, socket.SO_ERROR)
    if value == nil then
      return nil, system_error('connect_finish', err, eno, { address = address })
    end
    local code = tonumber(value) or 0
    if code == 0 or connected[code] then
      return 'connected'
    end
    if pending[code] then
      return 'pending', HostError.would_block('socket', 'connect_finish', { address = address })
    end
    return nil, system_error('connect_finish', nil, code, { address = address })
  end,
})
