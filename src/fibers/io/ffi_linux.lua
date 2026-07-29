-- One Linux FFI binding for LuaJIT FFI and cffi.
--
-- This module contains only C declarations, constants and native conversions.
-- fibers.io.posix owns Fibers handles, readiness delivery, network policy,
-- resolver deduplication, process lifecycle and capability reporting.

local BitOps = require('fibers.io.bitops')
local NativeError = require('fibers.io.native_error')
local Posix = require('fibers.io.posix')
local Address = require('fibers.net.address')

local AioProbe = {}
local cdef_done = setmetatable({}, { __mode = 'k' })

function AioProbe.available(ffi, C)
  if not ffi or not C then
    return false
  end
  local ok_cdef = cdef_done[ffi] == true
  if not ok_cdef then
    ok_cdef = pcall(function()
      ffi.cdef([[
      struct aiocb;
      int aio_read(struct aiocb *);
      int aio_write(struct aiocb *);
      int aio_fsync(int, struct aiocb *);
      int aio_error(const struct aiocb *);
      long aio_return(struct aiocb *);
      int aio_cancel(int, struct aiocb *);
      ]])
    end)
    if ok_cdef then
      cdef_done[ffi] = true
    end
  end
  if not ok_cdef then
    return false
  end
  local ok, available = pcall(function()
    return C.aio_read ~= nil
      and C.aio_write ~= nil
      and C.aio_fsync ~= nil
      and C.aio_error ~= nil
      and C.aio_return ~= nil
      and C.aio_cancel ~= nil
  end)
  return ok and available == true
end

local M = {}
local function native_context(opts)
  local ffi, C = assert(opts.ffi, 'ffi binding required'), opts.C or opts.ffi.C
  local convert = opts.tonumber_c or rawget(ffi, 'tonumber') or tonumber
  local native = { ffi = ffi, C = C, bit = opts.bit }
  function native.number(value)
    return convert(value) or tonumber(value)
  end
  function native.cdef(source)
    return pcall(ffi.cdef, source)
  end
  function native.errno()
    return ffi.errno()
  end
  function native.null(value)
    if value == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and value == nullptr
  end
  function native.strerror(errno)
    local ok, value = pcall(C.strerror, errno)
    return ok and not native.null(value) and ffi.string(value) or ('errno ' .. tostring(errno))
  end
  function native.vararg_int(value)
    if type(ffi.cast) == 'function' then
      local ok, converted = pcall(ffi.cast, 'int', value)
      if ok then
        return converted
      end
    end
    return value
  end
  function native.retry(fn)
    while true do
      local value = native.number(fn())
      if value ~= -1 then
        return value
      end
      local errno = native.errno()
      if errno ~= 4 then
        return nil, errno
      end
    end
  end
  native.cdef([[ int close(int fd); int pipe(int pipefd[2]); int fcntl(int fd, int cmd, ...); ]])
  local bit = assert(opts.bit, 'bit operations required')
  local function set_flag(fd, get_command, set_command, flag, enabled)
    local current, errno = native.retry(function()
      return C.fcntl(fd, get_command, native.vararg_int(0))
    end)
    if current == nil then
      return nil, errno
    end
    local value = enabled ~= false and bit.bor(current, flag) or bit.band(current, bit.bnot(flag))
    local result, next_errno = native.retry(function()
      return C.fcntl(fd, set_command, native.vararg_int(value))
    end)
    return result ~= nil and true or nil, next_errno
  end
  function native.set_cloexec(fd, enabled)
    return set_flag(fd, 1, 2, 1, enabled)
  end
  function native.set_nonblocking(fd, enabled)
    return set_flag(fd, 3, 4, 2048, enabled)
  end
  function native.close_fd(fd)
    if fd == nil or fd < 0 then
      return true
    end
    local result, errno = native.retry(function()
      return C.close(fd)
    end)
    return result ~= nil and true or nil, errno
  end
  function native.pipe(cloexec)
    local pair = ffi.new('int[2]')
    if native.number(C.pipe(pair)) ~= 0 then
      return nil, nil, native.errno()
    end
    local reader, writer = native.number(pair[0]), native.number(pair[1])
    if cloexec then
      local ok1, err1 = native.set_cloexec(reader, true)
      local ok2, err2 = native.set_cloexec(writer, true)
      if not ok1 or not ok2 then
        native.close_fd(reader)
        native.close_fd(writer)
        return nil, nil, err1 or err2
      end
    end
    return reader, writer
  end
  return native
end

local set_of = NativeError.set

function M.new(opts)
  opts = opts or {}
  local name = assert(opts.name, 'FFI binding name required')
  local ffi = assert(opts.ffi, 'FFI module required')
  local bit = opts.bit or select(1, BitOps.resolve())
  if not bit then
    return nil, 'bit operations unavailable'
  end

  local native = native_context({ ffi = ffi, C = opts.C or ffi.C, bit = bit, tonumber_c = opts.tonumber_c })
  local C, number = native.C, native.number
  local cdef_errors = {}
  local function cdef(source)
    local ok, err = native.cdef(source)
    if not ok then
      cdef_errors[#cdef_errors + 1] = tostring(err)
    end
  end

  cdef([[
    typedef long ssize_t;
    typedef unsigned long size_t;
    typedef int pid_t;
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    struct pollfd { int fd; short events; short revents; };

    int clock_gettime(int clk_id, struct timespec *tp);
    int nanosleep(const struct timespec *req, struct timespec *rem);
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);
    int close(int fd);
    int shutdown(int sockfd, int how);
    int pipe(int pipefd[2]);
    int fcntl(int fd, int cmd, ...);
    char *strerror(int errnum);
  ]])

  cdef([[
    struct sockaddr { unsigned short sa_family; char sa_data[14]; };
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
    struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
    struct sockaddr_storage {
      unsigned short ss_family;
      char __ss_padding[118];
      unsigned long __ss_align;
    };
    struct addrinfo {
      int ai_flags;
      int ai_family;
      int ai_socktype;
      int ai_protocol;
      unsigned int ai_addrlen;
      struct sockaddr *ai_addr;
      char *ai_canonname;
      struct addrinfo *ai_next;
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
    ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
      const struct sockaddr *dest_addr, unsigned int addrlen);
    ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
      struct sockaddr *src_addr, unsigned int *addrlen);
    int inet_pton(int af, const char *src, void *dst);
    const char *inet_ntop(int af, const void *src, char *dst, unsigned int size);
    unsigned short htons(unsigned short hostshort);
    unsigned short ntohs(unsigned short netshort);
    int unlink(const char *pathname);
    int getaddrinfo(const char *node, const char *service,
      const struct addrinfo *hints, struct addrinfo **res);
    void freeaddrinfo(struct addrinfo *res);
    const char *gai_strerror(int errcode);
  ]])

  cdef([[
    int fork(void);
    int execvp(const char *file, char *const argv[]);
    void _exit(int status);
    int dup2(int oldfd, int newfd);
    int open(const char *pathname, int flags, ...);
    int chdir(const char *path);
    int setpgid(pid_t pid, pid_t pgid);
    pid_t setsid(void);
    pid_t waitpid(pid_t pid, int *status, int options);
    int kill(pid_t pid, int sig);
    long syscall(long number, ...);
    int setenv(const char *name, const char *value, int overwrite);
    int unsetenv(const char *name);
    int clearenv(void);
    long sysconf(int name);
  ]])

  local CLOCK_MONOTONIC = 1
  local EINTR, EAGAIN, EWOULDBLOCK = 4, 11, 11
  local ENOTSOCK, ENOTCONN = 88, 107
  local EINVAL, ENOSYS, EMSGSIZE = 22, 38, 90
  local EINPROGRESS, EALREADY, EISCONN = 115, 114, 106
  local AF_UNIX, AF_INET, AF_INET6, AF_UNSPEC = 1, 2, 10, 0
  local SOCK_STREAM, SOCK_DGRAM = 1, 2
  local SOCK_NONBLOCK, SOCK_CLOEXEC = 2048, 524288
  local SOL_SOCKET, SO_REUSEADDR, SO_ERROR = 1, 2, 4
  local IPPROTO_TCP, TCP_NODELAY = 6, 1
  local SHUT_RD, SHUT_WR = 0, 1
  local MSG_TRUNC = 32
  local POLLIN, POLLOUT, POLLERR, POLLHUP, POLLNVAL = 0x001, 0x004, 0x008, 0x010, 0x020
  local O_RDONLY, O_WRONLY = 0, 1
  local WNOHANG = 1
  local SYS_pidfd_open = opts.sys_pidfd_open or 434
  local SYS_close_range = opts.sys_close_range or 436
  local SC_OPEN_MAX = opts.sc_open_max or 4

  local names = {
    [EINTR] = 'EINTR',
    [EAGAIN] = 'EAGAIN',
    [EINVAL] = 'EINVAL',
    [ENOSYS] = 'ENOSYS',
    [EMSGSIZE] = 'EMSGSIZE',
    [EINPROGRESS] = 'EINPROGRESS',
    [EALREADY] = 'EALREADY',
    [EISCONN] = 'EISCONN',
    [ENOTSOCK] = 'ENOTSOCK',
    [ENOTCONN] = 'ENOTCONN',
  }

  local function message(errno)
    return errno and native.strerror(errno) or nil
  end
  local function failure(result)
    local n = number(result)
    if n ~= -1 then
      return n
    end
    local errno = native.errno()
    return nil, errno, message(errno)
  end
  local function result_zero(result)
    local n = number(result)
    if n == 0 then
      return true
    end
    local errno = native.errno()
    return nil, errno, message(errno)
  end
  local function retry_call(fn)
    while true do
      local value = number(fn())
      if value ~= -1 then
        return value
      end
      local errno = native.errno()
      if errno ~= EINTR then
        return nil, errno, message(errno)
      end
    end
  end

  local binding = {
    name = name,
    family = 'numeric-fd',
    errors = {
      message = message,
      name = function(errno)
        return names[errno]
      end,
      interrupted = set_of(EINTR),
      again = set_of(EAGAIN, EWOULDBLOCK),
      connect_pending = set_of(EINPROGRESS, EALREADY, EAGAIN, EWOULDBLOCK),
      connected = set_of(EISCONN),
      not_socket = set_of(ENOTSOCK),
      not_connected = set_of(ENOTCONN),
      message_too_large = set_of(EMSGSIZE),
    },
    capabilities = { datagram_truncation = true },
  }

  binding.time = {
    now = function()
      local ts = ffi.new('struct timespec[1]')
      if number(C.clock_gettime(CLOCK_MONOTONIC, ts)) ~= 0 then
        error('clock_gettime(CLOCK_MONOTONIC) failed: ' .. message(native.errno()), 2)
      end
      return number(ts[0].tv_sec) + number(ts[0].tv_nsec) * 1e-9
    end,
    sleep = function(seconds)
      seconds = tonumber(seconds) or 0
      if seconds <= 0 then
        return true
      end
      local request, remainder = ffi.new('struct timespec[1]'), ffi.new('struct timespec[1]')
      local whole = math.floor(seconds)
      local nanos = math.floor((seconds - whole) * 1e9 + 0.5)
      if nanos >= 1000000000 then
        whole, nanos = whole + 1, nanos - 1000000000
      end
      request[0].tv_sec, request[0].tv_nsec = whole, nanos
      while true do
        if number(C.nanosleep(request, remainder)) == 0 then
          return true
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, message(errno)
        end
        request[0].tv_sec, request[0].tv_nsec = remainder[0].tv_sec, remainder[0].tv_nsec
      end
    end,
  }

  local fd_number = NativeError.number

  binding.poll = {
    poll_value = fd_number,
    number = fd_number,
    wait = function(plan, timeout)
      local count = #plan.records
      local fds = ffi.new('struct pollfd[?]', math.max(1, count))
      for i = 1, count do
        local record = plan.records[i]
        fds[i - 1].fd = record.fd
        local events = 0
        if record.read then
          events = bit.bor(events, POLLIN)
        end
        if record.write then
          events = bit.bor(events, POLLOUT)
        end
        fds[i - 1].events = events
      end
      local ready_count, errno, detail = retry_call(function()
        return C.poll(fds, count, timeout or -1)
      end)
      if ready_count == nil then
        error(detail or message(errno) or 'poll failed', 2)
      end
      local ready = {}
      if ready_count > 0 then
        for i = 1, count do
          local revents = number(fds[i - 1].revents)
          if revents ~= 0 then
            ready[#ready + 1] = {
              record = plan.records[i],
              read = bit.band(revents, bit.bor(POLLIN, POLLERR, POLLHUP, POLLNVAL)) ~= 0,
              write = bit.band(revents, bit.bor(POLLOUT, POLLERR, POLLNVAL)) ~= 0,
            }
          end
        end
      end
      return ready
    end,
  }

  binding.fd = {
    supported = function()
      return pcall(function()
        return C.read, C.write, C.close, C.pipe, C.fcntl
      end)
    end,
    validate = function(value)
      return assert(tonumber(value), 'fd must be numeric')
    end,
    poll_value = fd_number,
    number = fd_number,
    read = function(fd, maximum)
      maximum = math.max(0, tonumber(maximum) or 4096)
      if maximum == 0 then
        return ''
      end
      local buffer = ffi.new('char[?]', maximum)
      while true do
        local count = number(C.read(fd, buffer, maximum))
        if count >= 0 then
          return count == 0 and '' or ffi.string(buffer, count)
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, errno, message(errno)
        end
      end
    end,
    write = function(fd, bytes)
      while true do
        local count = number(C.write(fd, bytes, #bytes))
        if count >= 0 then
          return count
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, errno, message(errno)
        end
      end
    end,
    close = function(fd)
      local ok, errno = native.close_fd(fd)
      return ok or nil, errno, errno and message(errno) or nil
    end,
    shutdown = function(fd, mode)
      return result_zero(C.shutdown(fd, mode == 'read' and SHUT_RD or SHUT_WR))
    end,
    set_nonblocking = function(fd, enabled)
      local ok, errno = native.set_nonblocking(fd, enabled)
      return ok or nil, errno, errno and message(errno) or nil
    end,
    set_cloexec = function(fd, enabled)
      local ok, errno = native.set_cloexec(fd, enabled)
      return ok or nil, errno, errno and message(errno) or nil
    end,
    pipe = function()
      local reader, writer, errno = native.pipe(false)
      return reader, writer, errno, errno and message(errno) or nil
    end,
  }

  local function encode(address)
    local ok, value = pcall(Address.validate, address, 'socket address')
    if not ok then
      return nil
    end
    local kind = value.kind
    if kind == 'unix' then
      local path = value.path
      if #path >= 108 then
        return nil
      end
      local storage = ffi.new('struct sockaddr_un[1]')
      storage[0].sun_family = AF_UNIX
      ffi.copy(storage[0].sun_path, path, #path)
      storage[0].sun_path[#path] = 0
      return {
        family = AF_UNIX,
        native = {
          pointer = ffi.cast('struct sockaddr *', storage),
          length = ffi.offsetof('struct sockaddr_un', 'sun_path') + #path + 1,
          storage = storage,
        },
      }
    end
    local host, port = value.host, value.port
    if kind == 'inet6' then
      local storage, binary = ffi.new('struct sockaddr_in6[1]'), ffi.new('struct in6_addr[1]')
      if number(C.inet_pton(AF_INET6, host, binary)) ~= 1 then
        return nil
      end
      storage[0].sin6_family, storage[0].sin6_port = AF_INET6, C.htons(port)
      storage[0].sin6_flowinfo = value.flowinfo
      storage[0].sin6_scope_id = value.scope_id
      storage[0].sin6_addr = binary[0]
      return {
        family = AF_INET6,
        native = {
          pointer = ffi.cast('struct sockaddr *', storage),
          length = ffi.sizeof('struct sockaddr_in6'),
          storage = storage,
        },
      }
    end
    local storage, binary = ffi.new('struct sockaddr_in[1]'), ffi.new('struct in_addr[1]')
    if number(C.inet_pton(AF_INET, host, binary)) ~= 1 then
      return nil
    end
    storage[0].sin_family, storage[0].sin_port, storage[0].sin_addr = AF_INET, C.htons(port), binary[0]
    return {
      family = AF_INET,
      native = {
        pointer = ffi.cast('struct sockaddr *', storage),
        length = ffi.sizeof('struct sockaddr_in'),
        storage = storage,
      },
    }
  end

  local function decode_storage(storage, length)
    if storage == nil then
      return nil
    end
    if type(storage) == 'table' and storage.kind then
      return storage
    end
    local family = number(storage[0].ss_family)
    if family == AF_INET then
      local address, buffer = ffi.cast('struct sockaddr_in *', storage), ffi.new('char[64]')
      local ptr = C.inet_ntop(AF_INET, address.sin_addr, buffer, 64)
      if native.null(ptr) then
        return nil
      end
      return Address.ipv4(ffi.string(buffer), number(C.ntohs(address.sin_port)))
    elseif family == AF_INET6 then
      local address, buffer = ffi.cast('struct sockaddr_in6 *', storage), ffi.new('char[128]')
      local ptr = C.inet_ntop(AF_INET6, address.sin6_addr.s6_addr, buffer, 128)
      if native.null(ptr) then
        return nil
      end
      return Address.ipv6(ffi.string(buffer), number(C.ntohs(address.sin6_port)), {
        flowinfo = number(address.sin6_flowinfo),
        scope_id = number(address.sin6_scope_id),
      })
    elseif family == AF_UNIX then
      local address = ffi.cast('struct sockaddr_un *', storage)
      local maximum = math.max(0, tonumber(length or 0) - ffi.offsetof('struct sockaddr_un', 'sun_path'))
      local path = ffi.string(address.sun_path, math.min(maximum, 108))
      local zero = path:find('\0', 1, true)
      return Address.decode_unix(zero and path:sub(1, zero - 1) or path)
    end
  end

  local function query_address(fd, peer)
    local storage = ffi.new('struct sockaddr_storage[1]')
    local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
    local result = peer and C.getpeername(fd, ffi.cast('struct sockaddr *', storage), length)
      or C.getsockname(fd, ffi.cast('struct sockaddr *', storage), length)
    if number(result) ~= 0 then
      return nil
    end
    return decode_storage(storage, number(length[0]))
  end

  local support_cache = {}
  local function supports(kind)
    local family = kind == 'inet4' and AF_INET
      or kind == 'inet6' and AF_INET6
      or kind == 'unix' and AF_UNIX
      or tonumber(kind)
    if not family then
      return false
    end
    if support_cache[family] == nil then
      local fd = number(C.socket(family, SOCK_STREAM, 0))
      support_cache[family] = fd >= 0
      if fd >= 0 then
        native.close_fd(fd)
      end
    end
    return support_cache[family]
  end

  local function socket_open(family, kind)
    local socket_type = kind == 'datagram' and SOCK_DGRAM or SOCK_STREAM
    local fd = number(C.socket(family, socket_type + SOCK_NONBLOCK + SOCK_CLOEXEC, 0))
    if fd >= 0 then
      return fd
    end
    local first = native.errno()
    if first ~= EINVAL then
      return nil, first, message(first)
    end
    fd = number(C.socket(family, socket_type, 0))
    if fd >= 0 then
      return fd
    end
    local errno = native.errno()
    return nil, errno, message(errno)
  end

  local function set_option(fd, level, option, value)
    local native_level = level == 'tcp' and IPPROTO_TCP or SOL_SOCKET
    local native_option = option == 'nodelay' and TCP_NODELAY or SO_REUSEADDR
    local box = ffi.new('int[1]', value and 1 or 0)
    return result_zero(C.setsockopt(fd, native_level, native_option, box, ffi.sizeof('int')))
  end

  binding.net = {
    datagram = true,
    supports = supports,
    encode = encode,
    decode = function(value)
      return type(value) == 'table' and value.kind and value or decode_storage(value)
    end,
    is_unix = function(family)
      return family == AF_UNIX
    end,
    unlink = function(path)
      if path then
        pcall(C.unlink, path)
      end
    end,
    open = socket_open,
    set_option = set_option,
    bind = function(fd, address)
      return result_zero(C.bind(fd, address.pointer, address.length))
    end,
    listen = function(fd, backlog)
      return result_zero(C.listen(fd, backlog))
    end,
    accept = function(fd)
      local storage = ffi.new('struct sockaddr_storage[1]')
      local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      while true do
        local accepted
        local ok, value =
          pcall(C.accept4, fd, ffi.cast('struct sockaddr *', storage), length, SOCK_NONBLOCK + SOCK_CLOEXEC)
        if ok then
          accepted = number(value)
          if accepted >= 0 then
            return accepted, decode_storage(storage, number(length[0]))
          end
          local errno = native.errno()
          if errno == EINTR then
          elseif errno ~= ENOSYS and errno ~= EINVAL then
            return nil, nil, errno, message(errno)
          else
            break
          end
        else
          break
        end
      end
      while true do
        local accepted = number(C.accept(fd, ffi.cast('struct sockaddr *', storage), length))
        if accepted >= 0 then
          return accepted, decode_storage(storage, number(length[0]))
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, nil, errno, message(errno)
        end
      end
    end,
    connect = function(fd, address)
      return result_zero(C.connect(fd, address.pointer, address.length))
    end,
    socket_error = function(fd)
      local value, length = ffi.new('int[1]'), ffi.new('unsigned int[1]', ffi.sizeof('int'))
      if number(C.getsockopt(fd, SOL_SOCKET, SO_ERROR, value, length)) == 0 then
        return number(value[0])
      end
      local errno = native.errno()
      return errno, message(errno)
    end,
    query = query_address,
    receive = function(fd, maximum)
      maximum = math.max(0, math.floor(tonumber(maximum) or 65535))
      local buffer = ffi.new('unsigned char[?]', math.max(1, maximum))
      local storage = ffi.new('struct sockaddr_storage[1]')
      local length = ffi.new('unsigned int[1]', ffi.sizeof('struct sockaddr_storage'))
      while true do
        local count =
          number(C.recvfrom(fd, buffer, maximum, MSG_TRUNC, ffi.cast('struct sockaddr *', storage), length))
        if count >= 0 then
          local copied = math.min(count, maximum)
          return copied > 0 and ffi.string(buffer, copied) or '',
            decode_storage(storage, number(length[0])),
            {
              truncated = count > maximum,
              original_size = count > maximum and count or nil,
            }
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, nil, nil, errno, message(errno)
        end
      end
    end,
    send = function(fd, data, address)
      while true do
        local count = number(C.sendto(fd, data, #data, 0, address.pointer, address.length))
        if count >= 0 then
          return count
        end
        local errno = native.errno()
        if errno ~= EINTR then
          return nil, errno, message(errno)
        end
      end
    end,
  }

  if opts.resolver_enabled ~= false then
    binding.resolver = {
      supported = function()
        return pcall(function()
          return C.getaddrinfo, C.freeaddrinfo, C.gai_strerror
        end)
      end,
      query = function(_host, endpoint, resolve_opts)
        local hints = ffi.new('struct addrinfo[1]')
        local requested = (resolve_opts or {}).family or endpoint.family_hint
        hints[0].ai_family = requested == 'inet4' and AF_INET
          or requested == 'inet6' and AF_INET6
          or AF_UNSPEC
        hints[0].ai_socktype = SOCK_STREAM
        local result = ffi.new('struct addrinfo *[1]')
        local code = number(C.getaddrinfo(endpoint.host, tostring(endpoint.service), hints, result))
        if code ~= 0 then
          local pointer = C.gai_strerror(code)
          return nil, code, native.null(pointer) and ('getaddrinfo error ' .. code) or ffi.string(pointer)
        end
        local records = {}
        local current = result[0]
        while not native.null(current) do
          records[#records + 1] =
            decode_storage(ffi.cast('struct sockaddr_storage *', current.ai_addr), number(current.ai_addrlen))
          current = current.ai_next
        end
        C.freeaddrinfo(result[0])
        return records
      end,
      address = function(value, service)
        if value and value.port == 0 then
          return Address.with_port(value, tonumber(service) or 0)
        end
        return value
      end,
    }
  end

  binding.process = function(Fd)
    local Direct = require('fibers.io.process_direct')
    local signals = {
      hup = 1,
      int = 2,
      quit = 3,
      kill = 9,
      usr1 = 10,
      usr2 = 12,
      pipe = 13,
      alrm = 14,
      term = 15,
      chld = 17,
      cont = 18,
      stop = 19,
    }

    local function supported()
      local ok = pcall(function()
        return C.fork, C.execvp, C.dup2, C.waitpid, C.kill, C._exit
      end)
      return ok and binding.fd.supported(), 'required POSIX process functions unavailable'
    end

    local function environment(spec)
      if spec.env_mode == 'replace' and number(C.clearenv()) ~= 0 then
        return nil, native.errno()
      end
      for _, key in ipairs(spec.unset_env or {}) do
        if number(C.unsetenv(tostring(key))) ~= 0 then
          return nil, native.errno()
        end
      end
      for key, value in pairs(spec.env or {}) do
        if number(C.setenv(tostring(key), tostring(value), 1)) ~= 0 then
          return nil, native.errno()
        end
      end
      return true
    end

    local function close_inherited(spec, error_write)
      local keep, ordered = { [error_write] = true }, { error_write }
      for _, value in ipairs(spec.pass_fds or {}) do
        local fd = tonumber(value)
        if not fd or fd < 0 or fd ~= math.floor(fd) then
          return nil, EINVAL
        end
        if fd >= 3 and not keep[fd] then
          keep[fd], ordered[#ordered + 1] = true, fd
        end
        if fd >= 3 then
          local ok, errno = binding.fd.set_cloexec(fd, false)
          if not ok then
            return nil, errno
          end
        end
      end
      if spec.close_fds == false then
        return true
      end
      table.sort(ordered)
      local maximum = number(C.sysconf(SC_OPEN_MAX))
      if not maximum or maximum < 4 then
        maximum = 1024
      end
      local function close_interval(first, last)
        if first > last then
          return true
        end
        local ok, result = pcall(
          C.syscall,
          ffi.cast('long', SYS_close_range),
          ffi.cast('unsigned int', first),
          ffi.cast('unsigned int', last),
          ffi.cast('unsigned int', 0)
        )
        if ok and number(result) == 0 then
          return true
        end
        for fd = first, last do
          if not keep[fd] then
            C.close(fd)
          end
        end
        return true
      end
      local first = 3
      for i = 1, #ordered do
        local fd = ordered[i]
        if fd >= first then
          close_interval(first, fd - 1)
          first = fd + 1
        end
      end
      return close_interval(first, maximum - 1)
    end

    local function exec(argv)
      local buffers, vector = {}, ffi.new('char *[?]', #argv + 1)
      for i = 1, #argv do
        local value = tostring(argv[i])
        local buffer = ffi.new('char[?]', #value + 1)
        ffi.copy(buffer, value, #value)
        buffer[#value] = 0
        buffers[i], vector[i - 1] = buffer, buffer
      end
      vector[#argv] = nil
      C.execvp(argv[1], vector)
      local errno = native.errno()
      return nil, errno, message(errno)
    end

    local function wait(pid, nonblocking)
      local status = ffi.new('int[1]')
      local got, errno, detail = retry_call(function()
        return C.waitpid(pid, status, nonblocking and WNOHANG or 0)
      end)
      if got == nil then
        return nil, errno, detail
      end
      if got == 0 then
        return { kind = 'running' }
      end
      local raw = number(status[0])
      local low, signal = raw % 256, (raw % 256) % 128
      if signal == 0 then
        return { kind = 'exited', code = math.floor(raw / 256) % 256 }
      end
      if signal ~= 127 then
        return { kind = 'signalled', signal = signal, core_dumped = low >= 128 }
      end
      return { kind = 'stopped' }
    end

    return Direct.new({
      Fd = Fd,
      signals = signals,
      supported = supported,
      message = message,
      name_of = function(errno)
        return names[errno]
      end,
      interrupted = function(errno)
        return errno == EINTR
      end,
      again = function(errno)
        return errno == EAGAIN or errno == EWOULDBLOCK
      end,
      pipe = binding.fd.pipe,
      close = binding.fd.close,
      read = binding.fd.read,
      write = binding.fd.write,
      set_cloexec = binding.fd.set_cloexec,
      fork = function()
        local pid = number(C.fork())
        if pid ~= -1 then
          return pid
        end
        local errno = native.errno()
        return nil, errno, message(errno)
      end,
      exit = C._exit,
      chdir = function(path)
        return result_zero(C.chdir(path))
      end,
      setsid = function()
        return failure(C.setsid())
      end,
      setpgid = function(pid, group)
        return result_zero(C.setpgid(pid, group))
      end,
      environment = environment,
      stdio = {
        targets = { stdin = 0, stdout = 1, stderr = 2 },
        stdout = 1,
        same = function(a, b)
          return a == b
        end,
        duplicate = function(source, target)
          return failure(C.dup2(source, target))
        end,
        open_null = function(which)
          return failure(C.open('/dev/null', which == 'stdin' and O_RDONLY or O_WRONLY, native.vararg_int(0)))
        end,
        keep = function(value, error_write)
          return value == 0 or value == 1 or value == 2 or value == error_write
        end,
      },
      close_inherited = close_inherited,
      exec = exec,
      wait = wait,
      kill = function(pid, signal)
        return result_zero(C.kill(pid, signal))
      end,
      pidfd = function(pid)
        local ok, result = pcall(
          C.syscall,
          ffi.cast('long', SYS_pidfd_open),
          ffi.cast('int', pid),
          ffi.cast('unsigned int', 0)
        )
        if not ok or number(result) == -1 then
          return nil
        end
        return number(result)
      end,
    })
  end

  local UringProvider = require('fibers.file.uring_provider')
  local uring_supported = select(
    1,
    UringProvider.probe({ ffi = ffi, C = C, arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch) })
  )
  local aio_supported = AioProbe.available(ffi, C)
  if uring_supported then
    binding.capabilities.file = true
    binding.capabilities.file_backend = 'io_uring'
    binding.capabilities.file_io_uring = true
  end
  binding.capabilities.file_aio_detected = aio_supported
  binding.file = function(Fd)
    return function(_self, runtime, provider_opts)
      if uring_supported then
        local value = UringProvider.new(runtime, {
          ffi = ffi,
          C = C,
          fd = Fd,
          arch = opts.arch or ffi.arch or (rawget(_G, 'jit') and jit.arch),
          entries = provider_opts and provider_opts.ring_entries,
        })
        if value and (type(value.is_supported) ~= 'function' or value:is_supported()) then
          return value
        end
      end
      return require('fibers.file.worker_provider').new(runtime, provider_opts)
    end
  end

  binding.is_supported = function()
    local ok, reason = pcall(function()
      return C.clock_gettime, C.poll, C.read, C.write, C.close, C.pipe, C.fcntl
    end)
    if not ok then
      return false, reason or table.concat(cdef_errors, '; ')
    end
    local time_ok = pcall(binding.time.now)
    return time_ok, time_ok and nil or 'clock_gettime probe failed'
  end
  return binding
end

function M.load(module_name, name, opts)
  local ok, ffi = pcall(require, module_name)
  if not ok or type(ffi) ~= 'table' then
    return Posix.unavailable('fibers.io.' .. name, module_name .. ' module not available')
  end
  local bit, reason = BitOps.resolve()
  if not bit then
    return Posix.unavailable('fibers.io.' .. name, reason)
  end
  opts = opts or {}
  opts.name, opts.ffi, opts.bit, opts.C = name, ffi, bit, ffi.C
  local binding, binding_reason = M.new(opts)
  return binding and Posix.define(binding) or Posix.unavailable('fibers.io.' .. name, binding_reason)
end

return M
