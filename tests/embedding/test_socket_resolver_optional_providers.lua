package.path = table.concat(
  { './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/?.lua', package.path },
  ';'
)

local function with_modules(preloads, cleared, fn)
  local saved_preload, saved_loaded = {}, {}
  for name, loader in pairs(preloads) do
    saved_preload[name], package.preload[name] = package.preload[name], loader
  end
  for i = 1, #cleared do
    local name = cleared[i]
    saved_loaded[name], package.loaded[name] = package.loaded[name], nil
  end
  local ok, err = pcall(fn)
  for name, loader in pairs(saved_preload) do
    package.preload[name] = loader
  end
  for i = 1, #cleared do
    package.loaded[cleared[i]] = saved_loaded[cleared[i]]
  end
  assert(ok, err)
end

local function handle_methods(value)
  value.closed, value.blocking = false, true
  function value:read()
    return ''
  end
  function value:write(bytes)
    return #bytes
  end
  function value:close()
    self.closed = true
    return true
  end
  function value:setblocking(blocking)
    self.blocking = blocking
    return true
  end
  function value:fileno()
    return self.id
  end
  function value:shutdown()
    return true
  end
  return value
end

-- One luaposix table supplies descriptors, sockets and resolution.
do
  local next_fd, local_address, peer_address, resolver_calls = 40, {}, {}, {}
  local socket = {
    AF_UNIX = 1,
    AF_INET = 2,
    AF_INET6 = 10,
    AF_UNSPEC = 0,
    SOCK_STREAM = 1,
    SOCK_DGRAM = 2,
    SOL_SOCKET = 1,
    SO_REUSEADDR = 2,
    SO_ERROR = 4,
    IPPROTO_TCP = 6,
    TCP_NODELAY = 1,
  }
  function socket.socket(family)
    next_fd = next_fd + 1
    local_address[next_fd] = family == 1 and { family = family, path = '/tmp/fibers.sock' }
      or { family = family, addr = family == 10 and '::1' or '127.0.0.1', port = 43000 + next_fd }
    return next_fd
  end
  function socket.setsockopt()
    return 0
  end
  function socket.getsockopt()
    return 0
  end
  function socket.bind(fd, address)
    local_address[fd] = address
    if address.port == 0 then
      address.port = 43000 + fd
    end
    return 0
  end
  function socket.listen()
    return 0
  end
  function socket.getsockname(fd)
    return local_address[fd]
  end
  function socket.getpeername(fd)
    return peer_address[fd]
  end
  function socket.accept(fd)
    local child = fd + 100
    local family = local_address[fd].family
    local_address[child] = { family = family, addr = family == 10 and '::1' or '127.0.0.1', port = 43001 }
    peer_address[child] = { family = family, addr = family == 10 and '::2' or '127.0.0.2', port = 43002 }
    return child, peer_address[child]
  end
  function socket.connect(fd, address)
    peer_address[fd] = address
    return nil, 'in progress', 115
  end
  function socket.getaddrinfo(host, service, hints)
    resolver_calls[#resolver_calls + 1] = { host = host, service = service, hints = hints }
    return {
      { family = 2, addr = '127.0.0.1', port = 80 },
      { family = 2, addr = '127.0.0.1', port = 80 },
    }
  end

  local modules = {
    ['posix.poll'] = function()
      return {
        poll = function()
          return 0
        end,
      }
    end,
    ['posix.time'] = function()
      return {
        CLOCK_MONOTONIC = 1,
        clock_gettime = function()
          return { tv_sec = 0, tv_nsec = 0 }
        end,
        nanosleep = function()
          return true
        end,
      }
    end,
    ['posix.errno'] = function()
      return {
        EINTR = 4,
        EAGAIN = 11,
        EWOULDBLOCK = 11,
        EINPROGRESS = 115,
        EALREADY = 114,
        EISCONN = 106,
        EMSGSIZE = 90,
      }
    end,
    ['posix.fcntl'] = function()
      return {
        F_GETFL = 1,
        F_SETFL = 2,
        O_NONBLOCK = 4,
        F_GETFD = 5,
        F_SETFD = 6,
        FD_CLOEXEC = 1,
        fcntl = function()
          return 0
        end,
      }
    end,
    ['posix.unistd'] = function()
      return {
        read = function()
          return ''
        end,
        write = function(_, bytes)
          return #bytes
        end,
        close = function()
          return 0
        end,
        pipe = function()
          return 70, 71
        end,
        unlink = function()
          return 0
        end,
      }
    end,
    ['posix.sys.socket'] = function()
      return socket
    end,
  }
  local cleared = { 'fibers.host.luaposix' }
  for name in pairs(modules) do
    cleared[#cleared + 1] = name
  end
  with_modules(modules, cleared, function()
    local Host = require('fibers.host.luaposix')
    assert(Host.is_supported())
    local host = Host.new()
    local listener = assert(host:create_listener({ kind = 'inet4', host = '127.0.0.1', port = 0 }, {}))
    assert(listener:local_address().port > 0)
    local child, peer = assert(listener:accept())
    assert(child and peer.kind == 'inet4')
    local dial = assert(host:start_dial({ kind = 'inet4', host = '127.0.0.1', port = 80 }, {}))
    assert(dial._connect_pending)
    assert(dial:finish_connect() == dial)
    local addresses = assert(host:resolve({ host = 'localhost', service = 80 }, { family = 'inet4' }))
    assert(#addresses == 1 and addresses[1].host == '127.0.0.1')
    assert(
      resolver_calls[1].host == 'localhost'
        and resolver_calls[1].service == '80'
        and resolver_calls[1].hints.family == socket.AF_INET
    )
    listener:close()
    child:close()
    dial:close()
    host:close()
  end)
end

-- One Nixio object table supplies the same facilities.
do
  local next_id = 100
  local socket_options, socket_calls, resolver_calls = {}, {}, {}
  local function socket_object(family)
    next_id = next_id + 1
    local value = handle_methods({
      id = next_id,
      family = family,
      local_host = family == 'inet6' and '::1' or '127.0.0.1',
      local_port = 44000,
    })
    function value:setopt(level, option, setting)
      socket_options[#socket_options + 1] = { level = level, option = option, setting = setting }
      return true
    end
    function value:bind(host, port)
      socket_calls[#socket_calls + 1] = { method = 'bind', host = host, port = port }
      self.local_host, self.local_port = host, (tonumber(port) == 0 and 44000 or tonumber(port) or port)
      return true
    end
    function value:listen()
      return true
    end
    function value:getsockname()
      return self.local_host, self.local_port
    end
    function value:getpeername()
      if self.peer_host == nil then
        return nil
      end
      return self.peer_host, self.peer_port
    end
    function value:accept()
      local child = socket_object(self.family)
      child.peer_host, child.peer_port = '127.0.0.2', 44090
      return child, child.peer_host, child.peer_port
    end
    function value:connect(host, port)
      socket_calls[#socket_calls + 1] = { method = 'connect', host = host, port = port }
      self.peer_host, self.peer_port = host, port
      return nil, 'in progress', 115
    end
    function value:getopt()
      return 0
    end
    return value
  end
  local nixio = {
    const = { EINTR = 4, EAGAIN = 11, EWOULDBLOCK = 11, EINPROGRESS = 115, EALREADY = 114, EISCONN = 106 },
    gettime = function()
      return 0
    end,
    nanosleep = function()
      return true
    end,
    poll_flags = function(value)
      return type(value) == 'number' and {} or 1
    end,
    poll = function()
      return 0
    end,
    pipe = function()
      return handle_methods({ id = 1 }), handle_methods({ id = 2 })
    end,
    socket = function(family)
      return socket_object(family)
    end,
    errno = function()
      return 0
    end,
    strerror = function(number)
      return 'errno ' .. tostring(number)
    end,
    getaddrinfo = function(host, family, service)
      resolver_calls[#resolver_calls + 1] = { host = host, family = family, service = service }
      return {
        { family = 'inet', address = '127.0.0.1', port = 80 },
        { family = 'inet', address = '127.0.0.1', port = 80 },
      }
    end,
  }
  with_modules({
    nixio = function()
      return nixio
    end,
  }, { 'nixio', 'fibers.host.nixio' }, function()
    local Host = require('fibers.host.nixio')
    assert(Host.is_supported())
    local host = Host.new()
    local listener = assert(host:create_listener({ kind = 'inet4', host = '127.0.0.1', port = 0 }, {}))
    local listener_address = listener:local_address()
    assert(listener_address.host == '127.0.0.1' and listener_address.port == 44000)
    local child, peer = assert(listener:accept())
    assert(child and peer.kind == 'inet4')
    local dial = assert(host:start_dial({ kind = 'inet4', host = '127.0.0.1', port = 80 }, {}))
    assert(dial:finish_connect() == dial)
    assert(
      socket_calls[1].method == 'bind' and socket_calls[1].host == '127.0.0.1' and socket_calls[1].port == 0
    )
    assert(
      socket_calls[#socket_calls].method == 'connect'
        and socket_calls[#socket_calls].host == '127.0.0.1'
        and socket_calls[#socket_calls].port == 80
    )
    assert(socket_options[1].level == 'socket' and socket_options[1].option == 'reuseaddr')
    assert(
      socket_options[#socket_options].level == 'tcp' and socket_options[#socket_options].option == 'nodelay'
    )
    local addresses = assert(host:resolve({ host = 'localhost', service = 80 }, { family = 'inet4' }))
    assert(#addresses == 1 and addresses[1].port == 80)
    assert(
      resolver_calls[1].host == 'localhost'
        and resolver_calls[1].family == 'inet'
        and resolver_calls[1].service == '80'
    )
    listener:close()
    child:close()
    dial:close()
    host:close()
  end)
end

print('tests/embedding/test_socket_resolver_optional_providers.lua: ok')
