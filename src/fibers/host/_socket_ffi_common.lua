-- Shared Linux/POSIX stream and datagram socket implementation for FFI-backed host families.
--
-- This module deliberately handles numeric addresses only. Hostname resolution is
-- a separate host capability and never occurs implicitly in socket creation.

local HostError = require('fibers.host.error')
local SocketCore = require('fibers.host.socket_core')
local DatagramCore = require('fibers.host.datagram_core')
local FfiNative = require('fibers.host.ffi_native')

local Common = {}

function Common.new(opts)
  opts = opts or {}
  local prefix = opts.error_prefix or 'fibers.host.socket_ffi'
  local native = opts.native or FfiNative.new(opts)
  local ffi, C, tonumber_c = native.ffi, native.C, native.number
  local Fd = assert(opts.fd, 'numeric fd module required')

  local ok_cdef, cdef_err = native.cdef([[
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

  local errno = native.errno
  local is_null = native.null
  local strerror = native.strerror

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

  local function stream_supported()
    local ok = pcall(function()
      ffi.typeof('struct sockaddr_in')
      ffi.typeof('struct sockaddr_in6')
      ffi.typeof('struct sockaddr_un')
      return C.socket, C.bind, C.listen, C.connect, C.accept, C.getsockopt, C.inet_pton
    end)
    return ok and Fd.is_supported()
  end

  local function encode(address)
    local pointer, length, err, storage, family = sockaddr_for(address)
    if not pointer then
      return nil, err
    end
    return { family = family, native = pointer, length = length, storage = storage }
  end

  local function wrap(fd, host, name)
    return Fd.new(fd, { host = host, name = name, nonblocking = true })
  end

  local Stream = SocketCore.define({
    prefix = prefix,
    name = 'native',
    handle_family = 'numeric-socket',
    support_reason = prefix .. ': socket functions unavailable',
    supports = function()
      return stream_supported()
    end,
    encode = encode,
    is_unix = function(family)
      return family == AF_UNIX
    end,
    unlink = function(path)
      if path then
        pcall(C.unlink, path)
      end
    end,
    open = function(family)
      local fd, e = socket_fd(family, SOCK_STREAM)
      if not fd then
        return nil, system_error('socket', e)
      end
      return fd
    end,
    close_raw = close_raw,
    wrap = wrap,
    query = function(fd, peer)
      return query_address(fd, peer)
    end,
    decode_peer = function(value)
      return value
    end,
    set_reuse = function(fd, value, address)
      local ok, err = set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, value, 'setsockopt_reuseaddr')
      if not ok and type(err) == 'table' then
        err.address = address
      end
      return ok, err
    end,
    set_nodelay = function(fd, value, address)
      local ok, err = set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, value, 'setsockopt_nodelay')
      if not ok and type(err) == 'table' then
        err.address = address
      end
      return ok, err
    end,
    bind = function(fd, endpoint, address)
      if tonumber_c(C.bind(fd, endpoint.native, endpoint.length)) ~= 0 then
        return nil, system_error('bind', errno(), { address = address })
      end
      return true
    end,
    listen = function(fd, backlog, address)
      if tonumber_c(C.listen(fd, backlog)) ~= 0 then
        return nil, system_error('listen', errno(), { address = address })
      end
      return true
    end,
    accept = function(fd, address)
      local storage = ffi.new('struct sockaddr_storage[1]')
      local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      while true do
        local accepted
        local ok4, result = pcall(function()
          return C.accept4(fd, ffi.cast('struct sockaddr *', storage), length, SOCK_NONBLOCK + SOCK_CLOEXEC)
        end)
        if ok4 then
          accepted = tonumber_c(result)
          if accepted >= 0 then
            return accepted, address_from_storage(storage, tonumber_c(length[0]))
          end
          local e = errno()
          if e == EINTR then
          elseif e ~= ENOSYS and e ~= EINVAL then
            if e == EAGAIN or e == EWOULDBLOCK then
              return nil, nil, would_block('accept', { address = address })
            end
            return nil, nil, system_error('accept', e, { address = address })
          else
            break
          end
        else
          break
        end
      end
      while true do
        local accepted = tonumber_c(C.accept(fd, ffi.cast('struct sockaddr *', storage), length))
        if accepted >= 0 then
          return accepted, address_from_storage(storage, tonumber_c(length[0]))
        end
        local e = errno()
        if e == EINTR then
        elseif e == EAGAIN or e == EWOULDBLOCK then
          return nil, nil, would_block('accept', { address = address })
        else
          return nil, nil, system_error('accept', e, { address = address })
        end
      end
    end,
    connect = function(fd, endpoint, address)
      if tonumber_c(C.connect(fd, endpoint.native, endpoint.length)) == 0 then
        return 'connected'
      end
      local e = errno()
      if e == EISCONN then
        return 'connected'
      end
      if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
        return 'pending'
      end
      return nil, system_error('connect', e, { address = address })
    end,
    finish_connect = function(fd, _endpoint, address)
      local value = ffi.new('int[1]')
      local length = ffi.new('unsigned int[1]', ffi.sizeof('int'))
      if tonumber_c(C.getsockopt(fd, SOL_SOCKET, SO_ERROR, value, length)) ~= 0 then
        return nil, system_error('connect_finish', errno(), { address = address })
      end
      local e = tonumber_c(value[0])
      if e == 0 or e == EISCONN then
        return 'connected'
      end
      if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
        return 'pending', would_block('connect_finish', { address = address })
      end
      return nil, system_error('connect_finish', e, { address = address })
    end,
  })

  local Datagram = DatagramCore.define({
    prefix = prefix,
    name = 'native',
    support_reason = prefix .. ': datagram functions unavailable',
    is_supported = stream_supported,
    encode = function(address)
      local endpoint, err = encode(address)
      if endpoint and endpoint.family == AF_UNIX then
        return nil, HostError.unsupported('datagram', 'unix', { address = address })
      end
      return endpoint, err
    end,
    open = function(family, address)
      local fd, e = socket_fd(family, SOCK_DGRAM)
      if not fd then
        return nil, datagram_system_error('socket', e, { address = address })
      end
      return fd
    end,
    close_raw = close_raw,
    set_reuse = function(fd, value, address)
      local ok, err = set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, value, 'setsockopt_reuseaddr')
      if not ok and type(err) == 'table' then
        err.address = address
      end
      return ok, err
    end,
    bind = function(fd, endpoint, address)
      if tonumber_c(C.bind(fd, endpoint.native, endpoint.length)) ~= 0 then
        return nil, datagram_system_error('bind', errno(), { address = address })
      end
      return true
    end,
    wrap = wrap,
    query = function(fd)
      return query_address(fd, false)
    end,
    receive = function(fd, max_size, _family, address)
      max_size = math.max(0, math.floor(tonumber(max_size) or 65535))
      local buffer = ffi.new('unsigned char[?]', math.max(1, max_size))
      local storage = ffi.new('struct sockaddr_storage[1]')
      local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      while true do
        local n = tonumber_c(
          C.recvfrom(fd, buffer, max_size, MSG_TRUNC, ffi.cast('struct sockaddr *', storage), length)
        )
        if n and n >= 0 then
          local copied = math.min(n, max_size)
          return {
            data = copied > 0 and ffi.string(buffer, copied) or '',
            peer = address_from_storage(storage, tonumber_c(length[0])),
            local_address = address,
            truncated = n > max_size,
            original_size = n > max_size and n or nil,
            flags = {},
          }
        end
        local e = errno()
        if e == EINTR then
        elseif e == EAGAIN or e == EWOULDBLOCK then
          return nil, datagram_would_block('receive_from', { address = address })
        else
          return nil, datagram_system_error('receive_from', e, { address = address })
        end
      end
    end,
    send = function(fd, data, endpoint, destination)
      while true do
        local n = tonumber_c(C.sendto(fd, data, #data, 0, endpoint.native, endpoint.length))
        if n and n >= 0 then
          return n
        end
        local e = errno()
        if e == EINTR then
        elseif e == EAGAIN or e == EWOULDBLOCK then
          return nil, datagram_would_block('send_to', { address = destination })
        else
          return nil, datagram_system_error('send_to', e, { address = destination })
        end
      end
    end,
  })

  Stream.create_datagram = Datagram.create_datagram

  return Stream
end

return Common
