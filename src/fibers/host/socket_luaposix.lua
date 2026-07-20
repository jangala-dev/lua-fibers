-- luaposix stream-socket provider.
--
-- Numeric IPv4, IPv6 and Unix addresses only. Name resolution remains an
-- explicit host capability supplied by resolver_luaposix.

local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local function unsupported(reason)
  local value = Provider.unsupported('fibers.host.socket_luaposix', reason, { 'create_listener', 'start_dial' })
  value.supports_ipv4 = function() return false end
  value.supports_ipv6 = function() return false end
  value.supports_unix = function() return false end
  return value
end

local ok_socket, socket = pcall(require, 'posix.sys.socket')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_errno, errno = pcall(require, 'posix.errno')
if not ok_socket or type(socket) ~= 'table'
    or not ok_unistd or type(unistd) ~= 'table'
    or not ok_errno or type(errno) ~= 'table' then
  return unsupported('requires posix.sys.socket, posix.unistd and posix.errno')
end

local Fd = require('fibers.host.fd_luaposix')
local PosixError = require('fibers.host.luaposix_error')
local Socket = {}

local AF_INET = socket.AF_INET
local AF_INET6 = socket.AF_INET6
local AF_UNIX = socket.AF_UNIX
local SOCK_STREAM = socket.SOCK_STREAM
local SOL_SOCKET = socket.SOL_SOCKET
local SO_REUSEADDR = socket.SO_REUSEADDR
local SO_ERROR = socket.SO_ERROR
local IPPROTO_TCP = socket.IPPROTO_TCP
local TCP_NODELAY = socket.TCP_NODELAY

local EAGAIN = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or EAGAIN
local EINTR = errno.EINTR
local EINPROGRESS = errno.EINPROGRESS
local EALREADY = errno.EALREADY
local EISCONN = errno.EISCONN

local function system_error(action, err, eno, fields)
  return PosixError.system('socket', action, err, eno, fields)
end

local function would_block(action, fields)
  return HostError.would_block('socket', action, fields)
end

local function address_kind(address)
  return address and (address.kind or address.family)
end

local function sockaddr_for(address)
  local kind = address_kind(address)
  if kind == 'inet4' then
    if AF_INET == nil then return nil, HostError.unsupported('socket', 'ipv4', { address = address }) end
    return { family = AF_INET, addr = address.host, port = tonumber(address.port) }, AF_INET
  end
  if kind == 'inet6' then
    if AF_INET6 == nil then return nil, HostError.unsupported('socket', 'ipv6', { address = address }) end
    return {
      family = AF_INET6,
      addr = address.host,
      port = tonumber(address.port),
      flowinfo = tonumber(address.flowinfo) or 0,
      scope_id = tonumber(address.scope_id) or 0,
    }, AF_INET6
  end
  if kind == 'unix' then
    if AF_UNIX == nil then return nil, HostError.unsupported('socket', 'unix', { address = address }) end
    return { family = AF_UNIX, path = address.path }, AF_UNIX
  end
  return nil, HostError.invalid_argument('socket', 'address', { address = address })
end

local function address_from(value, family_hint)
  if type(value) ~= 'table' then return nil end
  local family = value.family or family_hint
  if family == AF_INET or family == 'inet' or family == 'inet4' then
    return { kind = 'inet4', family = 'inet4', host = value.addr or value.host, port = tonumber(value.port) or 0 }
  end
  if family == AF_INET6 or family == 'inet6' then
    return {
      kind = 'inet6', family = 'inet6', host = value.addr or value.host, port = tonumber(value.port) or 0,
      flowinfo = tonumber(value.flowinfo) or 0, scope_id = tonumber(value.scope_id) or 0,
    }
  end
  if family == AF_UNIX or family == 'unix' then
    return { kind = 'unix', family = 'unix', path = value.path or value.addr or value.host }
  end
  return nil
end

local function query_address(fd, peer, family_hint)
  local value = peer and socket.getpeername(fd) or socket.getsockname(fd)
  return address_from(value, family_hint)
end

local function set_option(fd, level, option, value, action, fields)
  if level == nil or option == nil or type(socket.setsockopt) ~= 'function' then
    return nil, HostError.unsupported('socket', action, fields)
  end
  value = PosixError.option(value)
  local ok, err, eno = socket.setsockopt(fd, level, option, value)
  if ok == nil then return nil, system_error(action, err, eno, fields) end
  return true
end

local function close_raw(fd)
  if fd ~= nil then pcall(unistd.close, fd) end
end

local function wrap_socket(fd, host, name, family)
  local handle, err = Fd.new(fd, { host = host, name = name, nonblocking = true, cloexec = true })
  if not handle then return nil, HostError.normalise(err, { domain = 'socket', action = 'wrap' }) end
  handle.family = 'numeric-socket'
  handle.socket_family = family
  handle.local_address = function(self) return query_address(self.fd, false, family) end
  handle.peer_address_value = function(self) return query_address(self.fd, true, family) end
  return handle
end

local function socket_api_supported()
  return SOCK_STREAM ~= nil
    and type(socket.socket) == 'function'
    and type(socket.bind) == 'function'
    and type(socket.listen) == 'function'
    and type(socket.accept) == 'function'
    and type(socket.connect) == 'function'
    and type(socket.getsockname) == 'function'
    and type(socket.getpeername) == 'function'
    and type(socket.getsockopt) == 'function'
    and Fd.is_supported()
end

local support_cache = {}
local function family_supported(family)
  if family == nil or not socket_api_supported() then return false end
  if support_cache[family] == nil then
    local fd = socket.socket(family, SOCK_STREAM, 0)
    support_cache[family] = fd ~= nil
    if fd ~= nil then close_raw(fd) end
  end
  return support_cache[family]
end

function Socket.supports_ipv4() return family_supported(AF_INET) end
function Socket.supports_ipv6() return family_supported(AF_INET6) end
function Socket.supports_unix() return family_supported(AF_UNIX) and type(unistd.unlink) == 'function' end
function Socket.is_supported() return Socket.supports_ipv4() or Socket.supports_ipv6() or Socket.supports_unix() end
function Socket.support_reason() return Socket.is_supported() and nil or 'required luaposix stream socket functions unavailable' end

function Socket.create_listener(host, address, opts)
  opts = opts or {}
  local sockaddr, family_or_err = sockaddr_for(address)
  if not sockaddr then return nil, family_or_err end
  local family = family_or_err
  local fd, err, eno = socket.socket(family, SOCK_STREAM, 0)
  if fd == nil then return nil, system_error('socket', err, eno, { address = address }) end

  local handle, wrap_err = wrap_socket(fd, host, opts.name or 'luaposix-listener', family)
  if not handle then return nil, wrap_err end

  if family ~= AF_UNIX and opts.reuse_address ~= false then
    local ok, option_err = set_option(fd, SOL_SOCKET, SO_REUSEADDR, true, 'setsockopt_reuseaddr', { address = address })
    if not ok then handle:close(option_err); return nil, option_err end
  end
  if family == AF_UNIX and opts.unlink_existing == true then pcall(unistd.unlink, address.path) end

  local ok, bind_err, bind_eno = socket.bind(fd, sockaddr)
  if ok == nil then
    local failure = system_error('bind', bind_err, bind_eno, { address = address })
    handle:close(failure)
    return nil, failure
  end
  ok, bind_err, bind_eno = socket.listen(fd, tonumber(opts.backlog) or 128)
  if ok == nil then
    local failure = system_error('listen', bind_err, bind_eno, { address = address })
    handle:close(failure)
    return nil, failure
  end

  local raw_close = handle._close
  local unix_path = family == AF_UNIX and address.path or nil
  handle._close = function(self, reason)
    local closed, close_err, detail = raw_close(self, reason)
    if unix_path and opts.unlink_on_close ~= false then pcall(unistd.unlink, unix_path) end
    return closed, close_err, detail
  end
  handle.address = query_address(fd, false, family) or address
  handle.local_address = function(self) return self.address end
  handle.accept = function(self)
    self:clear_readable()
    while true do
      local accepted, peer_or_err, accept_eno = socket.accept(self.fd)
      if accepted ~= nil then
        local child, child_err = wrap_socket(
          accepted, host, (opts.name or 'listener') .. ':accepted', family
        )
        if not child then return nil, nil, child_err end
        if family ~= AF_UNIX and opts.nodelay ~= false then
          local set, nodelay_err = set_option(
            accepted, IPPROTO_TCP, TCP_NODELAY, true, 'setsockopt_nodelay', { address = self.address }
          )
          if not set then child:close(nodelay_err); return nil, nil, nodelay_err end
        end
        local peer = address_from(peer_or_err, family) or query_address(accepted, true, family)
        child.peer_address = peer
        child.local_address_value = query_address(accepted, false, family)
        return child, peer
      end
      if accept_eno == EINTR then
        -- retry
      elseif accept_eno == EAGAIN or accept_eno == EWOULDBLOCK then
        return nil, nil, would_block('accept', { address = self.address })
      else
        return nil, nil, system_error('accept', peer_or_err, accept_eno, { address = self.address })
      end
    end
  end
  return handle
end

function Socket.start_dial(host, address, opts)
  opts = opts or {}
  local sockaddr, family_or_err = sockaddr_for(address)
  if not sockaddr then return nil, family_or_err end
  local family = family_or_err
  local fd, err, eno = socket.socket(family, SOCK_STREAM, 0)
  if fd == nil then return nil, system_error('socket', err, eno, { address = address }) end

  local handle, wrap_err = wrap_socket(fd, host, opts.name or 'luaposix-dial', family)
  if not handle then return nil, wrap_err end

  if opts.local_address then
    local local_sa, local_family_or_err = sockaddr_for(opts.local_address)
    if not local_sa then handle:close(local_family_or_err); return nil, local_family_or_err end
    if local_family_or_err ~= family then
      local failure = HostError.invalid_argument('socket', 'bind', {
        address = opts.local_address, message = 'local and peer address families differ',
      })
      handle:close(failure)
      return nil, failure
    end
    local bound, bind_err, bind_eno = socket.bind(fd, local_sa)
    if bound == nil then
      local failure = system_error('bind', bind_err, bind_eno, { address = opts.local_address })
      handle:close(failure)
      return nil, failure
    end
  end
  if family ~= AF_UNIX and opts.nodelay ~= false then
    local ok, option_err = set_option(fd, IPPROTO_TCP, TCP_NODELAY, true, 'setsockopt_nodelay', { address = address })
    if not ok then handle:close(option_err); return nil, option_err end
  end

  handle.target_address = address
  handle._connect_complete = false
  handle._connect_pending = false
  local connected, connect_err, connect_eno = socket.connect(fd, sockaddr)
  if connected ~= nil then
    handle._connect_complete = true
  elseif connect_eno == EINPROGRESS or connect_eno == EALREADY
      or connect_eno == EAGAIN or connect_eno == EWOULDBLOCK then
    handle._connect_pending = true
  elseif connect_eno == EISCONN then
    handle._connect_complete = true
  else
    local failure = system_error('connect', connect_err, connect_eno, { address = address })
    handle:close(failure)
    return nil, failure
  end

  handle.finish_connect = function(self)
    if self._connect_complete then return self, query_address(self.fd, true, family) or address end
    self:clear_writable()
    local value, get_err, get_eno = socket.getsockopt(self.fd, SOL_SOCKET, SO_ERROR)
    if value == nil then
      return nil, nil, system_error('connect_finish', get_err, get_eno, { address = address })
    end
    local e = tonumber(value) or 0
    if e == 0 or e == EISCONN then
      self._connect_complete = true
      self._connect_pending = false
      return self, query_address(self.fd, true, family) or address
    end
    if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
      return nil, nil, would_block('connect_finish', { address = address })
    end
    return nil, nil, system_error('connect_finish', nil, e, { address = address })
  end
  return handle
end

return Socket
