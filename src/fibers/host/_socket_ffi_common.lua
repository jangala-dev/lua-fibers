-- Shared Linux/POSIX stream and datagram socket implementation for FFI-backed host families.
--
-- This module deliberately handles numeric addresses only. Hostname resolution is
-- a separate host capability and never occurs implicitly in socket creation.

local HostError = require('fibers.host.error')

local Common = {}

local function make_unsupported(prefix, reason)
  return {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
    create_listener = function()
      return nil, HostError.unsupported('socket', 'listen', { reason = reason })
    end,
    start_dial = function()
      return nil, HostError.unsupported('socket', 'dial', { reason = reason })
    end,
    create_datagram = function()
      return nil, HostError.unsupported('datagram', 'open', { reason = reason })
    end,
  }
end

local function make_tonumber(ffi)
  local toint = rawget(ffi, 'tonumber') or tonumber
  return function(value)
    local n = toint(value)
    if n == nil then
      n = tonumber(value)
    end
    return n
  end
end

function Common.new(opts)
  opts = opts or {}
  local prefix = opts.error_prefix or 'fibers.host.socket_ffi'
  local ffi = assert(opts.ffi, 'ffi provider required')
  local C = opts.C or ffi.C
  local Fd = assert(opts.fd, 'numeric fd module required')
  local tonumber_c = opts.tonumber_c or make_tonumber(ffi)

  local ok_cdef, cdef_err = pcall(function()
    ffi.cdef([[
      struct sockaddr {
        unsigned short sa_family;
        char sa_data[14];
      };
      struct in_addr { unsigned int s_addr; };
      struct sockaddr_in {
        unsigned short sin_family;
        unsigned short sin_port;
        struct in_addr sin_addr;
        unsigned char sin_zero[8];
      };
      struct in6_addr { unsigned char s6_addr[16]; };
      struct sockaddr_in6 {
        unsigned short sin6_family;
        unsigned short sin6_port;
        unsigned int sin6_flowinfo;
        struct in6_addr sin6_addr;
        unsigned int sin6_scope_id;
      };
      struct sockaddr_un {
        unsigned short sun_family;
        char sun_path[108];
      };
      struct sockaddr_storage {
        unsigned short ss_family;
        char __ss_padding[118];
        unsigned long __ss_align;
      };

      int socket(int domain, int type, int protocol);
      int bind(int sockfd, const struct sockaddr *addr, unsigned int addrlen);
      int listen(int sockfd, int backlog);
      int connect(int sockfd, const struct sockaddr *addr, unsigned int addrlen);
      int accept(int sockfd, struct sockaddr *addr, unsigned int *addrlen);
      int accept4(int sockfd, struct sockaddr *addr, unsigned int *addrlen, int flags);
      int getsockname(int sockfd, struct sockaddr *addr, unsigned int *addrlen);
      int getpeername(int sockfd, struct sockaddr *addr, unsigned int *addrlen);
      int getsockopt(int sockfd, int level, int optname, void *optval, unsigned int *optlen);
      int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
      long sendto(int sockfd, const void *buf, unsigned long len, int flags,
        const struct sockaddr *dest_addr, unsigned int addrlen);
      long recvfrom(int sockfd, void *buf, unsigned long len, int flags,
        struct sockaddr *src_addr, unsigned int *addrlen);
      int inet_pton(int af, const char *src, void *dst);
      const char *inet_ntop(int af, const void *src, char *dst, unsigned int size);
      unsigned short htons(unsigned short hostshort);
      unsigned short ntohs(unsigned short netshort);
      int unlink(const char *pathname);
    ]])
  end)
  if not ok_cdef then
    opts._cdef_err = cdef_err
  end

  local AF_UNIX = 1
  local AF_INET = 2
  local AF_INET6 = 10
  local SOCK_STREAM = 1
  local SOCK_DGRAM = 2
  local SOCK_NONBLOCK = 2048
  local SOCK_CLOEXEC = 524288
  local SOL_SOCKET = 1
  local SO_REUSEADDR = 2
  local SO_ERROR = 4
  local IPPROTO_TCP = 6
  local TCP_NODELAY = 1
  local MSG_TRUNC = 32

  local EINTR = 4
  local EAGAIN = 11
  local EWOULDBLOCK = 11
  local EINVAL = 22
  local EMSGSIZE = 90
  local ENOSYS = 38
  local EINPROGRESS = 115
  local EALREADY = 114
  local EISCONN = 106

  local function errno()
    return ffi.errno()
  end

  local function is_null(ptr)
    if ptr == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and ptr == nullptr
  end

  local function strerror(e)
    local ok, s = pcall(function()
      return C.strerror(e)
    end)
    if not ok or is_null(s) then
      return 'errno ' .. tostring(e)
    end
    return ffi.string(s)
  end

  local errno_names = {
    [EAGAIN] = 'EAGAIN',
    [EINPROGRESS] = 'EINPROGRESS',
    [EALREADY] = 'EALREADY',
    [EISCONN] = 'EISCONN',
  }

  local function system_error(action, e, fields)
    fields = fields or {}
    fields.temporary = fields.temporary == true
    return HostError.system('socket', action, strerror(e), errno_names[e], e, fields)
  end

  local function would_block(action, fields)
    return HostError.would_block('socket', action, fields)
  end

  local function datagram_system_error(action, e, fields)
    if e == EMSGSIZE then
      return HostError.message_too_large('datagram', action, fields)
    end
    fields = fields or {}
    fields.temporary = fields.temporary == true
    return HostError.system('datagram', action, strerror(e), errno_names[e], e, fields)
  end

  local function datagram_would_block(action, fields)
    return HostError.would_block('datagram', action, fields)
  end

  local function infer_kind(address)
    if address.kind == 'inet4' or address.family == 'inet4' then
      return 'inet4'
    end
    if address.kind == 'inet6' or address.family == 'inet6' then
      return 'inet6'
    end
    if address.kind == 'unix' or address.family == 'unix' then
      return 'unix'
    end
    local host = address.host or address.address or '0.0.0.0'
    if string.find(host, ':', 1, true) then
      return 'inet6'
    end
    return 'inet4'
  end

  local function sockaddr_for(address)
    address = address or {}
    local kind = infer_kind(address)
    if kind == 'unix' then
      local path = address.path
      if type(path) ~= 'string' or path == '' then
        return nil, nil, HostError.system('socket', 'address', 'Unix socket path must be non-empty')
      end
      if #path >= 108 then
        return nil, nil, HostError.system('socket', 'address', 'Unix socket path is too long', 'ENAMETOOLONG')
      end
      local sa = ffi.new('struct sockaddr_un[1]')
      sa[0].sun_family = AF_UNIX
      ffi.copy(sa[0].sun_path, path, #path)
      sa[0].sun_path[#path] = 0
      local length = ffi.offsetof('struct sockaddr_un', 'sun_path') + #path + 1
      return ffi.cast('struct sockaddr *', sa), length, nil, sa, AF_UNIX
    end

    local host = address.host or address.address
    local port = tonumber(address.port)
    if type(host) ~= 'string' or host == '' or not port or port < 0 or port > 65535 then
      return nil, nil, HostError.system('socket', 'address', 'invalid numeric internet socket address')
    end

    if kind == 'inet6' then
      local sa = ffi.new('struct sockaddr_in6[1]')
      sa[0].sin6_family = AF_INET6
      sa[0].sin6_port = C.htons(port)
      sa[0].sin6_flowinfo = tonumber(address.flowinfo) or 0
      sa[0].sin6_scope_id = tonumber(address.scope_id) or 0
      local addr = ffi.new('struct in6_addr[1]')
      local rc = tonumber_c(C.inet_pton(AF_INET6, host, addr))
      if rc ~= 1 then
        return nil,
          nil,
          HostError.system('socket', 'address', 'invalid numeric IPv6 address', 'EINVAL', EINVAL, {
            address = address,
          })
      end
      sa[0].sin6_addr = addr[0]
      return ffi.cast('struct sockaddr *', sa), ffi.sizeof('struct sockaddr_in6'), nil, sa, AF_INET6
    end

    local sa = ffi.new('struct sockaddr_in[1]')
    sa[0].sin_family = AF_INET
    sa[0].sin_port = C.htons(port)
    local addr = ffi.new('struct in_addr[1]')
    local rc = tonumber_c(C.inet_pton(AF_INET, host, addr))
    if rc ~= 1 then
      return nil,
        nil,
        HostError.system('socket', 'address', 'invalid numeric IPv4 address', 'EINVAL', EINVAL, {
          address = address,
        })
    end
    sa[0].sin_addr = addr[0]
    return ffi.cast('struct sockaddr *', sa), ffi.sizeof('struct sockaddr_in'), nil, sa, AF_INET
  end

  local function address_from_storage(storage, length)
    local family = tonumber_c(storage[0].ss_family)
    if family == AF_INET then
      local sa = ffi.cast('struct sockaddr_in *', storage)
      local buf = ffi.new('char[?]', 64)
      local ptr = C.inet_ntop(AF_INET, sa.sin_addr, buf, 64)
      if is_null(ptr) then
        return nil
      end
      return {
        kind = 'inet4',
        family = 'inet4',
        host = ffi.string(buf),
        port = tonumber_c(C.ntohs(sa.sin_port)),
      }
    end
    if family == AF_INET6 then
      local sa = ffi.cast('struct sockaddr_in6 *', storage)
      local buf = ffi.new('char[?]', 128)
      local ptr = C.inet_ntop(AF_INET6, sa.sin6_addr.s6_addr, buf, 128)
      if is_null(ptr) then
        return nil
      end
      return {
        kind = 'inet6',
        family = 'inet6',
        host = ffi.string(buf),
        port = tonumber_c(C.ntohs(sa.sin6_port)),
        flowinfo = tonumber_c(sa.sin6_flowinfo),
        scope_id = tonumber_c(sa.sin6_scope_id),
      }
    end
    if family == AF_UNIX then
      local sa = ffi.cast('struct sockaddr_un *', storage)
      local max = math.max(0, tonumber(length or 0) - ffi.offsetof('struct sockaddr_un', 'sun_path'))
      local raw = ffi.string(sa.sun_path, math.min(max, 108))
      local nul = string.find(raw, '\0', 1, true)
      if nul then
        raw = string.sub(raw, 1, nul - 1)
      end
      return { kind = 'unix', family = 'unix', path = raw }
    end
    return { kind = 'unknown', family = family }
  end

  local function socket_fd(family, socket_type)
    socket_type = socket_type or SOCK_STREAM
    local fd = tonumber_c(C.socket(family, socket_type + SOCK_NONBLOCK + SOCK_CLOEXEC, 0))
    if fd and fd >= 0 then
      return fd
    end
    local first = errno()
    if first ~= EINVAL then
      return nil, first
    end
    fd = tonumber_c(C.socket(family, socket_type, 0))
    if fd and fd >= 0 then
      return fd
    end
    return nil, errno()
  end

  local function set_int_option(fd, level, option, value, action)
    local box = ffi.new('int[1]', value and 1 or 0)
    local rc = tonumber_c(C.setsockopt(fd, level, option, box, ffi.sizeof('int')))
    if rc == 0 then
      return true
    end
    local e = errno()
    return nil, system_error(action, e)
  end

  local function close_raw(fd)
    if fd and fd >= 0 then
      pcall(function()
        C.close(fd)
      end)
    end
  end

  local function query_address(fd, peer)
    local storage = ffi.new('struct sockaddr_storage[1]')
    local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
    local rc
    if peer then
      rc = tonumber_c(C.getpeername(fd, ffi.cast('struct sockaddr *', storage), length))
    else
      rc = tonumber_c(C.getsockname(fd, ffi.cast('struct sockaddr *', storage), length))
    end
    if rc ~= 0 then
      return nil
    end
    return address_from_storage(storage, tonumber_c(length[0]))
  end

  local Socket = {}

  function Socket.is_supported()
    local ok, reason = pcall(function()
      ffi.typeof('struct sockaddr_in')
      ffi.typeof('struct sockaddr_in6')
      ffi.typeof('struct sockaddr_un')
      return C.socket, C.bind, C.listen, C.connect, C.accept, C.getsockopt, C.inet_pton
    end)
    if not ok then
      return false, reason or cdef_err
    end
    return Fd.is_supported()
  end

  function Socket.support_reason()
    local ok, reason = Socket.is_supported()
    if ok then
      return nil
    end
    return reason or (prefix .. ': socket functions unavailable')
  end

  local function wrap_socket(fd, wrap_opts)
    local handle, err = Fd.new(fd, wrap_opts)
    if not handle then
      return nil, err
    end
    handle.family = 'numeric-socket'
    handle.local_address = function(self)
      return query_address(self.fd, false)
    end
    handle.peer_address_value = function(self)
      return query_address(self.fd, true)
    end
    return handle
  end

  function Socket.create_listener(host, address, listener_opts)
    listener_opts = listener_opts or {}
    local sockaddr, length, addr_err, storage, family = sockaddr_for(address)
    if not sockaddr then
      return nil, addr_err
    end
    local fd, socket_errno = socket_fd(family, SOCK_STREAM)
    if not fd then
      return nil, system_error('socket', socket_errno, { address = address })
    end

    if listener_opts.reuse_address ~= false and family ~= AF_UNIX then
      local ok, option_err = set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, true, 'setsockopt_reuseaddr')
      if not ok then
        close_raw(fd)
        return nil, option_err
      end
    end
    if family == AF_UNIX and listener_opts.unlink_existing == true then
      C.unlink(address.path)
    end

    local rc = tonumber_c(C.bind(fd, sockaddr, length))
    if rc ~= 0 then
      local e = errno()
      close_raw(fd)
      return nil, system_error('bind', e, { address = address })
    end
    rc = tonumber_c(C.listen(fd, tonumber(listener_opts.backlog) or 128))
    if rc ~= 0 then
      local e = errno()
      close_raw(fd)
      return nil, system_error('listen', e, { address = address })
    end

    local handle, wrap_err = wrap_socket(fd, {
      host = host,
      name = listener_opts.name or 'native-listener',
      nonblocking = true,
    })
    if not handle then
      return nil, wrap_err
    end
    local raw_close = handle._close
    local unix_path = family == AF_UNIX and address.path or nil
    handle._close = function(self, reason)
      local ok, err, detail = raw_close(self, reason)
      if unix_path and listener_opts.unlink_on_close ~= false then
        pcall(function()
          C.unlink(unix_path)
        end)
      end
      return ok, err, detail
    end
    handle.address = query_address(fd, false) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.accept = function(self)
      -- Readiness is level-like advice.  Consume the delivered hint before the
      -- authoritative accept call so EAGAIN returns the driver to epoll.
      self:clear_readable()
      local peer_storage = ffi.new('struct sockaddr_storage[1]')
      local peer_length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      local accepted
      while true do
        local ok_accept4, result = pcall(function()
          return C.accept4(
            self.fd,
            ffi.cast('struct sockaddr *', peer_storage),
            peer_length,
            SOCK_NONBLOCK + SOCK_CLOEXEC
          )
        end)
        if ok_accept4 then
          accepted = tonumber_c(result)
          if accepted >= 0 then
            break
          end
          local e = errno()
          if e == EINTR then
            -- retry
          elseif e == ENOSYS or e == EINVAL then
            accepted = nil
            break
          elseif e == EAGAIN or e == EWOULDBLOCK then
            return nil, nil, would_block('accept', { address = self.address })
          else
            return nil, nil, system_error('accept', e, { address = self.address })
          end
        else
          accepted = nil
          break
        end
      end
      if accepted == nil then
        while true do
          accepted = tonumber_c(C.accept(self.fd, ffi.cast('struct sockaddr *', peer_storage), peer_length))
          if accepted >= 0 then
            break
          end
          local e = errno()
          if e == EINTR then
            -- retry
          elseif e == EAGAIN or e == EWOULDBLOCK then
            return nil, nil, would_block('accept', { address = self.address })
          else
            return nil, nil, system_error('accept', e, { address = self.address })
          end
        end
      end
      local child, child_err = wrap_socket(accepted, {
        host = host,
        name = (listener_opts.name or 'listener') .. ':accepted',
        nonblocking = true,
      })
      if not child then
        -- Fd.new closes the descriptor when its setup fails. Closing it again
        -- here could affect an unrelated descriptor if the number is reused.
        return nil, nil, child_err
      end
      if listener_opts.nodelay ~= false and tonumber_c(peer_storage[0].ss_family) ~= AF_UNIX then
        local ok, nodelay_err = set_int_option(accepted, IPPROTO_TCP, TCP_NODELAY, true, 'setsockopt_nodelay')
        if not ok then
          child:close('TCP_NODELAY failed')
          return nil, nil, nodelay_err
        end
      end
      local peer = address_from_storage(peer_storage, tonumber_c(peer_length[0]))
      child.peer_address = peer
      child.local_address_value = query_address(accepted, false)
      return child, peer
    end
    return handle
  end

  function Socket.start_dial(host, address, dial_opts)
    dial_opts = dial_opts or {}
    local sockaddr, length, addr_err, storage, family = sockaddr_for(address)
    if not sockaddr then
      return nil, addr_err
    end
    local fd, socket_errno = socket_fd(family, SOCK_STREAM)
    if not fd then
      return nil, system_error('socket', socket_errno, { address = address })
    end

    if dial_opts.local_address then
      local local_sa, local_length, local_err = sockaddr_for(dial_opts.local_address)
      if not local_sa then
        close_raw(fd)
        return nil, local_err
      end
      local rc = tonumber_c(C.bind(fd, local_sa, local_length))
      if rc ~= 0 then
        local e = errno()
        close_raw(fd)
        return nil, system_error('bind', e, { address = dial_opts.local_address })
      end
    end
    if dial_opts.nodelay ~= false and family ~= AF_UNIX then
      local ok, option_err = set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, true, 'setsockopt_nodelay')
      if not ok then
        close_raw(fd)
        return nil, option_err
      end
    end

    local handle, wrap_err = wrap_socket(fd, {
      host = host,
      name = dial_opts.name or 'native-dial',
      nonblocking = true,
    })
    if not handle then
      return nil, wrap_err
    end
    handle.target_address = address
    handle._connect_complete = false
    handle._connect_pending = false

    local rc = tonumber_c(C.connect(fd, sockaddr, length))
    if rc == 0 then
      handle._connect_complete = true
    else
      local e = errno()
      if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
        handle._connect_pending = true
      elseif e == EISCONN then
        handle._connect_complete = true
      else
        handle:close('connect failed')
        return nil, system_error('connect', e, { address = address })
      end
    end

    handle.finish_connect = function(self)
      if self._connect_complete then
        return self, query_address(self.fd, true) or address
      end
      -- A readiness notification may be stale.  Clear it before SO_ERROR so a
      -- still-pending connection waits for a fresh writable event.
      self:clear_writable()
      local value = ffi.new('int[1]')
      local value_length = ffi.new('unsigned int[1]', ffi.sizeof('int'))
      local got = tonumber_c(C.getsockopt(self.fd, SOL_SOCKET, SO_ERROR, value, value_length))
      if got ~= 0 then
        local e = errno()
        return nil, nil, system_error('connect_finish', e, { address = address })
      end
      local e = tonumber_c(value[0])
      if e == 0 or e == EISCONN then
        self._connect_complete = true
        self._connect_pending = false
        return self, query_address(self.fd, true) or address
      end
      if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
        return nil, nil, would_block('connect_finish', { address = address })
      end
      return nil, nil, system_error('connect_finish', e, { address = address })
    end
    return handle
  end

  function Socket.create_datagram(host, address, datagram_opts)
    datagram_opts = datagram_opts or {}
    local sockaddr, length, addr_err, _storage, family = sockaddr_for(address)
    if not sockaddr then
      return nil, addr_err
    end
    if family == AF_UNIX then
      return nil, HostError.unsupported('datagram', 'unix', { address = address })
    end

    local fd, socket_errno = socket_fd(family, SOCK_DGRAM)
    if not fd then
      return nil, datagram_system_error('socket', socket_errno, { address = address })
    end
    if datagram_opts.reuse_address == true then
      local ok, option_err = set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, true, 'setsockopt_reuseaddr')
      if not ok then
        close_raw(fd)
        return nil, option_err
      end
    end
    local rc = tonumber_c(C.bind(fd, sockaddr, length))
    if rc ~= 0 then
      local e = errno()
      close_raw(fd)
      return nil, datagram_system_error('bind', e, { address = address })
    end

    local handle, wrap_err = wrap_socket(fd, {
      host = host,
      name = datagram_opts.name or 'native-datagram',
      nonblocking = true,
    })
    if not handle then
      return nil, wrap_err
    end
    handle.address = query_address(fd, false) or address
    handle.local_address = function(self)
      return self.address
    end

    handle.recv_from = function(self, max_size)
      self:clear_readable()
      max_size = math.max(0, math.floor(tonumber(max_size) or 65535))
      local buffer = ffi.new('unsigned char[?]', math.max(1, max_size))
      local peer_storage = ffi.new('struct sockaddr_storage[1]')
      local peer_length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      while true do
        local n = tonumber_c(
          C.recvfrom(
            self.fd,
            buffer,
            max_size,
            MSG_TRUNC,
            ffi.cast('struct sockaddr *', peer_storage),
            peer_length
          )
        )
        if n and n >= 0 then
          local copied = math.min(n, max_size)
          local data = copied > 0 and ffi.string(buffer, copied) or ''
          return {
            data = data,
            peer = address_from_storage(peer_storage, tonumber_c(peer_length[0])),
            local_address = self.address,
            truncated = n > max_size,
            original_size = n > max_size and n or nil,
            flags = {},
          }
        end
        local e = errno()
        if e == EINTR then
          -- retry
        elseif e == EAGAIN or e == EWOULDBLOCK then
          return nil, datagram_would_block('receive_from', { address = self.address })
        else
          return nil, datagram_system_error('receive_from', e, { address = self.address })
        end
      end
    end

    handle.send_to = function(self, data, destination)
      self:clear_writable()
      local target, target_length, target_err = sockaddr_for(destination)
      if not target then
        return nil, target_err
      end
      while true do
        local n = tonumber_c(C.sendto(self.fd, data, #data, 0, target, target_length))
        if n and n >= 0 then
          return n
        end
        local e = errno()
        if e == EINTR then
          -- retry
        elseif e == EAGAIN or e == EWOULDBLOCK then
          return nil, datagram_would_block('send_to', { address = destination })
        else
          return nil, datagram_system_error('send_to', e, { address = destination })
        end
      end
    end
    return handle
  end

  return Socket
end

Common.unsupported = make_unsupported

return Common
