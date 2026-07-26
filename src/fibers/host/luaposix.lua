-- One LuaPOSIX binding.  This file contains only native bindings and
-- conversions; fibers.host.posix supplies all Fibers semantics.

local Posix = require('fibers.host.posix')
local NativeError = require('fibers.host.native_error')
local BitOps = require('fibers.host.bitops')
local Address = require('fibers.socket.address')
local HostError = require('fibers.host.error')

local ok_poll, poll = pcall(require, 'posix.poll')
local ok_time, time = pcall(require, 'posix.time')
local ok_errno, errno = pcall(require, 'posix.errno')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_socket, socket = pcall(require, 'posix.sys.socket')
local ok_signal, signal = pcall(require, 'posix.signal')
local ok_wait, syswait = pcall(require, 'posix.sys.wait')
local ok_stdlib, stdlib = pcall(require, 'posix.stdlib')
local bit = select(1, BitOps.resolve())

local available = ok_poll
  and ok_time
  and ok_errno
  and ok_unistd
  and ok_fcntl
  and ok_socket
  and type(poll) == 'table'
  and type(time) == 'table'
  and type(errno) == 'table'
  and type(unistd) == 'table'
  and type(fcntl) == 'table'
  and type(socket) == 'table'
  and bit ~= nil

if not available then
  return Posix.unavailable(
    'fibers.host.luaposix',
    'requires luaposix poll, time, errno, unistd, fcntl and socket modules'
  )
end

local names = {}
for name, value in pairs(errno) do
  if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
    names[value] = names[value] or name
  end
end
local native_error = NativeError.new({ names = names })
local AF = { inet4 = socket.AF_INET, inet6 = socket.AF_INET6, unix = socket.AF_UNIX }
local support_cache = {}

local set_of, fd_number = NativeError.set, NativeError.number

local function split(a, b)
  return native_error.split(a, b)
end

local function message(number)
  if number == nil then
    return nil
  end
  local text = native_error.detail('native operation failed', nil, number)
  return text
end

local function set_flag(fd, get_cmd, set_cmd, flag, enabled)
  local current, a, b = fcntl.fcntl(fd, get_cmd)
  if current == nil then
    local msg, eno = split(a, b)
    return nil, eno, msg
  end
  local next_flags = enabled and bit.bor(current, flag) or bit.band(current, bit.bnot(flag))
  local ok, x, y = fcntl.fcntl(fd, set_cmd, next_flags)
  if ok == nil then
    local msg, eno = split(x, y)
    return nil, eno, msg
  end
  return true
end

local function normalise_address(address)
  local ok, value = pcall(Address.validate, address, 'socket address')
  if ok then
    return value
  end
  return nil, HostError.invalid_argument('socket', 'address', { address = address })
end

local function encode(address)
  local value, err = normalise_address(address)
  if not value then
    return nil, err
  end
  local kind, family = value.kind, AF[value.kind]
  if kind == 'unix' then
    return { family = family, native = { family = family, path = value.path } }
  end
  return {
    family = family,
    native = {
      family = family,
      addr = value.host,
      port = value.port,
      flowinfo = kind == 'inet6' and value.flowinfo or nil,
      scope_id = kind == 'inet6' and value.scope_id or nil,
    },
  }
end

local function decode(value, family)
  if type(value) ~= 'table' then
    return nil
  end
  family = value.family or family
  if family == AF.inet4 or family == 'inet' or family == 'inet4' then
    return Address.ipv4(value.addr or value.host, tonumber(value.port) or 0)
  end
  if family == AF.inet6 or family == 'inet6' then
    return Address.ipv6(value.addr or value.host, tonumber(value.port) or 0, value)
  end
  if family == AF.unix or family == 'unix' then
    return Address.decode_unix(value.path or value.addr or value.host)
  end
end

local binding = {
  name = 'luaposix',
  family = 'numeric-fd',
  errors = {
    message = message,
    name = function(number)
      return names[number]
    end,
    interrupted = set_of(errno.EINTR),
    again = set_of(errno.EAGAIN, errno.EWOULDBLOCK or errno.EAGAIN),
    connect_pending = set_of(
      errno.EINPROGRESS,
      errno.EALREADY,
      errno.EAGAIN,
      errno.EWOULDBLOCK or errno.EAGAIN
    ),
    connected = set_of(errno.EISCONN),
    not_socket = set_of(errno.ENOTSOCK),
    not_connected = set_of(errno.ENOTCONN),
    message_too_large = set_of(errno.EMSGSIZE),
  },
}

binding.time = {
  now = function()
    local ts, err = time.clock_gettime(time.CLOCK_MONOTONIC)
    if not ts then
      error('posix.clock_gettime(CLOCK_MONOTONIC) failed: ' .. tostring(err), 2)
    end
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
  end,
  sleep = function(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
      return true
    end
    local sec = math.floor(seconds)
    local nsec = math.floor((seconds - sec) * 1e9 + 0.5)
    if nsec >= 1000000000 then
      sec, nsec = sec + 1, nsec - 1000000000
    end
    local request = { tv_sec = sec, tv_nsec = nsec }
    while true do
      local ok, a, b, remainder = time.nanosleep(request)
      if ok then
        return true
      end
      local _, eno = split(a, b)
      if eno == errno.EINTR and remainder then
        request = remainder
      else
        return nil, message(eno) or tostring(a or b)
      end
    end
  end,
}

binding.poll = {
  poll_value = fd_number,
  number = fd_number,
  wait = function(plan, timeout)
    local fds = {}
    for i = 1, #plan.records do
      local record = plan.records[i]
      local events = {}
      if record.read then
        events.IN = true
      end
      if record.write then
        events.OUT = true
      end
      fds[record.fd] = { events = events }
    end
    local count, a, b = poll.poll(fds, timeout)
    if count == nil then
      local _, eno = split(a, b)
      if eno == errno.EINTR then
        return nil, 'poll-interrupted'
      end
      error(message(eno) or tostring(a or b or 'posix.poll failed'), 2)
    end
    local ready = {}
    if count > 0 then
      for fd, info in pairs(fds) do
        local events = info.revents
        if events then
          ready[#ready + 1] = {
            record = plan.by_fd[fd],
            read = events.IN or events.HUP or events.ERR or events.NVAL,
            write = events.OUT or events.ERR or events.NVAL,
          }
        end
      end
    end
    return ready
  end,
}

binding.fd = {
  supported = function()
    return type(unistd.read) == 'function'
      and type(unistd.write) == 'function'
      and type(unistd.close) == 'function'
      and type(unistd.pipe) == 'function'
  end,
  validate = function(value)
    return assert(tonumber(value), 'fd must be numeric')
  end,
  poll_value = fd_number,
  number = fd_number,
  read = function(fd, maximum)
    local value, a, b = unistd.read(fd, maximum)
    if value ~= nil then
      return value
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  write = function(fd, bytes)
    local value, a, b = unistd.write(fd, bytes)
    if value ~= nil then
      return value
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  close = function(fd)
    local ok, a, b = unistd.close(fd)
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  shutdown = function(fd, mode)
    if type(socket.shutdown) ~= 'function' then
      return true
    end
    local ok, a, b = socket.shutdown(fd, mode == 'read' and (socket.SHUT_RD or 0) or (socket.SHUT_WR or 1))
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  set_nonblocking = function(fd, enabled)
    return set_flag(fd, fcntl.F_GETFL, fcntl.F_SETFL, fcntl.O_NONBLOCK or 0, enabled)
  end,
  set_cloexec = function(fd, enabled)
    if fcntl.F_GETFD == nil or fcntl.F_SETFD == nil or fcntl.FD_CLOEXEC == nil then
      return true
    end
    return set_flag(fd, fcntl.F_GETFD, fcntl.F_SETFD, fcntl.FD_CLOEXEC, enabled)
  end,
  pipe = function()
    local reader, writer, a, b = unistd.pipe()
    if reader then
      return reader, writer
    end
    local msg, eno = split(a, b)
    return nil, nil, eno, msg
  end,
}

local function supported(family, kind)
  if family == nil or socket[kind == 'datagram' and 'SOCK_DGRAM' or 'SOCK_STREAM'] == nil then
    return false
  end
  local key = tostring(family) .. ':' .. tostring(kind)
  if support_cache[key] == nil then
    local raw = socket.socket(family, kind == 'datagram' and socket.SOCK_DGRAM or socket.SOCK_STREAM, 0)
    support_cache[key] = raw ~= nil
    if raw ~= nil then
      pcall(unistd.close, raw)
    end
  end
  return support_cache[key]
end

binding.net = {
  datagram = socket.SOCK_DGRAM ~= nil,
  reason = 'required luaposix socket functions unavailable',
  supports = function(kind)
    return supported(AF[kind] or kind, 'stream')
  end,
  encode = encode,
  decode = decode,
  is_unix = function(family)
    return family == AF.unix
  end,
  unlink = function(path)
    if path and type(unistd.unlink) == 'function' then
      pcall(unistd.unlink, path)
    end
  end,
  open = function(family, kind)
    local value, a, b =
      socket.socket(family, kind == 'datagram' and socket.SOCK_DGRAM or socket.SOCK_STREAM, 0)
    if value then
      return value
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  set_option = function(fd, level, name, value)
    local native_level = level == 'tcp' and socket.IPPROTO_TCP or socket.SOL_SOCKET
    local native_name = name == 'nodelay' and socket.TCP_NODELAY or socket.SO_REUSEADDR
    if native_level == nil or native_name == nil or type(socket.setsockopt) ~= 'function' then
      return nil, nil, 'socket option unavailable'
    end
    local ok, a, b = socket.setsockopt(fd, native_level, native_name, value and 1 or 0)
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  bind = function(fd, address)
    local ok, a, b = socket.bind(fd, address)
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  listen = function(fd, backlog)
    local ok, a, b = socket.listen(fd, backlog)
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  accept = function(fd)
    while true do
      local child, peer, eno = socket.accept(fd)
      if child ~= nil then
        return child, peer
      end
      if eno ~= errno.EINTR then
        return nil, nil, eno, peer
      end
    end
  end,
  connect = function(fd, address)
    local ok, a, b = socket.connect(fd, address)
    if ok ~= nil then
      return true
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  socket_error = function(fd)
    local value, a, b = socket.getsockopt(fd, socket.SOL_SOCKET, socket.SO_ERROR)
    if value == nil then
      local msg, eno = split(a, b)
      return eno, msg
    end
    return tonumber(value) or 0
  end,
  query = function(fd, peer)
    return peer and socket.getpeername(fd) or socket.getsockname(fd)
  end,
  receive = function(fd, maximum)
    local data, peer, eno = socket.recvfrom(fd, maximum)
    if data ~= nil then
      return data, peer, { truncation_unknown = true, receive_limit = maximum }
    end
    return nil, nil, nil, eno, peer
  end,
  send = function(fd, data, address)
    local count, a, b = socket.sendto(fd, data, address)
    if count ~= nil then
      return tonumber(count) or #data
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
}

binding.resolver = {
  supported = function()
    return type(socket.getaddrinfo) == 'function' and socket.SOCK_STREAM ~= nil
  end,
  reason = 'luaposix getaddrinfo unavailable',
  query = function(_host, endpoint, opts)
    local requested = opts.family or endpoint.family_hint
    local family = requested == 'inet4' and socket.AF_INET
      or requested == 'inet6' and socket.AF_INET6
      or socket.AF_UNSPEC
      or 0
    local records, a, b = socket.getaddrinfo(endpoint.host, tostring(endpoint.service), {
      family = family,
      socktype = socket.SOCK_STREAM,
    })
    if records then
      return records
    end
    local msg, eno = split(a, b)
    return nil, eno, msg
  end,
  address = function(value, service)
    if type(value) ~= 'table' then
      return nil
    end
    local address = decode(value, value.family)
    if address and address.port == 0 then
      return Address.with_port(address, tonumber(service) or 0)
    end
    return address
  end,
}

binding.process = function(Fd)
  local Direct = require('fibers.host.process_direct')
  local process_available = ok_signal
    and ok_wait
    and ok_stdlib
    and type(signal) == 'table'
    and type(syswait) == 'table'
    and type(stdlib) == 'table'

  local function process_supported()
    local required = process_available
        and {
          unistd.fork,
          unistd.execp,
          unistd._exit,
          unistd.dup2,
          unistd.chdir,
          unistd.setpid,
          unistd.sysconf,
          fcntl.open,
          signal.kill,
          syswait.wait,
          stdlib.getenv,
          stdlib.setenv,
        }
      or {}
    if not process_available or syswait.WNOHANG == nil then
      return false, 'required luaposix process modules unavailable'
    end
    for i = 1, #required do
      if type(required[i]) ~= 'function' then
        return false, 'required luaposix process functions unavailable'
      end
    end
    return true
  end

  local function environment(spec)
    if spec.env_mode == 'replace' then
      local current = stdlib.getenv()
      if type(current) ~= 'table' then
        return nil, errno.EINVAL
      end
      for name in pairs(current) do
        local ok, _, eno = stdlib.setenv(tostring(name), nil)
        if ok == nil then
          return nil, eno
        end
      end
    end
    for _, name in ipairs(spec.unset_env or {}) do
      local ok, _, eno = stdlib.setenv(tostring(name), nil)
      if ok == nil then
        return nil, eno
      end
    end
    for name, value in pairs(spec.env or {}) do
      local ok, _, eno = stdlib.setenv(tostring(name), tostring(value))
      if ok == nil then
        return nil, eno
      end
    end
    return true
  end

  local signals = {
    hup = signal.SIGHUP,
    int = signal.SIGINT,
    quit = signal.SIGQUIT,
    kill = signal.SIGKILL,
    usr1 = signal.SIGUSR1,
    usr2 = signal.SIGUSR2,
    pipe = signal.SIGPIPE,
    alrm = signal.SIGALRM,
    term = signal.SIGTERM,
    chld = signal.SIGCHLD,
    cont = signal.SIGCONT,
    stop = signal.SIGSTOP,
  }

  return Direct.new({
    Fd = Fd,
    signals = signals,
    supported = process_supported,
    message = message,
    name_of = function(number)
      return names[number]
    end,
    interrupted = function(number)
      return number == errno.EINTR
    end,
    again = function(number)
      return number == errno.EAGAIN or number == (errno.EWOULDBLOCK or errno.EAGAIN)
    end,
    pipe = binding.fd.pipe,
    close = binding.fd.close,
    read = binding.fd.read,
    write = binding.fd.write,
    set_cloexec = binding.fd.set_cloexec,
    fork = function()
      local pid, a, b = unistd.fork()
      if pid ~= nil then
        return pid
      end
      local msg, eno = split(a, b)
      return nil, eno, msg
    end,
    exit = unistd._exit,
    chdir = function(path)
      local ok, a, b = unistd.chdir(path)
      if ok ~= nil then
        return true
      end
      local _, eno = split(a, b)
      return nil, eno
    end,
    setsid = function()
      local ok, a, b = unistd.setpid('s', 0)
      if ok ~= nil then
        return true
      end
      local _, eno = split(a, b)
      return nil, eno
    end,
    setpgid = function(pid, group)
      local ok, a, b = unistd.setpid('p', pid, group)
      if ok ~= nil then
        return true
      end
      local _, eno = split(a, b)
      return nil, eno
    end,
    environment = environment,
    stdio = {
      targets = { stdin = 0, stdout = 1, stderr = 2 },
      stdout = 1,
      same = function(a, b)
        return a == b
      end,
      duplicate = function(source, target)
        local ok, a, b = unistd.dup2(source, target)
        if ok ~= nil then
          return true
        end
        local _, eno = split(a, b)
        return nil, eno
      end,
      open_null = function(which)
        local value, a, b = fcntl.open('/dev/null', which == 'stdin' and fcntl.O_RDONLY or fcntl.O_WRONLY, 0)
        if value ~= nil then
          return value
        end
        local _, eno = split(a, b)
        return nil, eno
      end,
      keep = function(value, error_write)
        return value == 0 or value == 1 or value == 2 or value == error_write
      end,
    },
    close_inherited = function(spec, error_write)
      local keep = { [error_write] = true }
      for _, value in ipairs(spec.pass_fds or {}) do
        local fd = tonumber(value)
        if not fd or fd < 0 or fd ~= math.floor(fd) then
          return nil, errno.EINVAL
        end
        keep[fd] = true
        if fd >= 3 then
          local ok, eno = binding.fd.set_cloexec(fd, false)
          if not ok then
            return nil, eno
          end
        end
      end
      if spec.close_fds == false then
        return true
      end
      local maximum = tonumber(unistd.sysconf(unistd._SC_OPEN_MAX or 4)) or 1024
      for fd = 3, maximum - 1 do
        if not keep[fd] then
          unistd.close(fd)
        end
      end
      return true
    end,
    exec = function(argv)
      local args = { [0] = argv[1] }
      for i = 2, #argv do
        args[i - 1] = argv[i]
      end
      local _, _, eno = unistd.execp(argv[1], args)
      return nil, eno
    end,
    wait = function(pid, nonblocking)
      local got, how, value = syswait.wait(pid, nonblocking and syswait.WNOHANG or nil)
      if got == nil then
        local _, eno = split(how, value)
        return nil, eno
      end
      if got == 0 or how == 'running' then
        return { kind = 'running' }
      end
      if how == 'stopped' then
        return { kind = 'stopped' }
      end
      if how == 'exited' then
        return { kind = 'exited', code = value }
      end
      if how == 'killed' or how == 'signaled' or how == 'signalled' then
        return { kind = 'signalled', signal = value }
      end
      return nil, errno.EINVAL, 'unexpected wait status ' .. tostring(how)
    end,
    kill = function(pid, number)
      local ok, a, b = signal.kill(pid, number)
      if ok ~= nil then
        return true
      end
      local msg, eno = split(a, b)
      return nil, eno, msg
    end,
  })
end

binding.is_supported = function()
  return binding.fd.supported()
    and type(poll.poll) == 'function'
    and type(time.clock_gettime) == 'function'
    and time.CLOCK_MONOTONIC ~= nil
end

return Posix.define(binding)
