package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function with_modules(preloads, cleared, fn)
  local saved_preload, saved_loaded = {}, {}
  for name, loader in pairs(preloads) do
    saved_preload[name] = package.preload[name]
    package.preload[name] = loader
  end
  for i = 1, #cleared do
    local name = cleared[i]
    saved_loaded[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  local ok, err = pcall(fn)
  for name, loader in pairs(saved_preload) do package.preload[name] = loader end
  for i = 1, #cleared do package.loaded[cleared[i]] = saved_loaded[cleared[i]] end
  assert(ok, err)
end

local function numeric_handle(fd)
  local handle = { fd = fd, capabilities = {} }
  function handle:clear_readable() self.readable = false end
  function handle:clear_writable() self.writable = false end
  function handle:mark_readable() self.readable = true end
  function handle:mark_writable() self.writable = true end
  function handle:_close() self.closed = true; return true end
  function handle:close(reason) return self:_close(reason) end
  return handle
end

-- luaposix stream sockets and resolver.
do
  local next_fd = 40
  local local_by_fd, peer_by_fd = {}, {}
  local socket_mod = {
    AF_UNIX = 1, AF_INET = 2, AF_INET6 = 10, AF_UNSPEC = 0,
    SOCK_STREAM = 1, SOL_SOCKET = 1, SO_REUSEADDR = 2, SO_ERROR = 4,
    IPPROTO_TCP = 6, TCP_NODELAY = 1,
  }
  function socket_mod.socket(family, kind)
    assert_eq(kind, socket_mod.SOCK_STREAM)
    next_fd = next_fd + 1
    local_by_fd[next_fd] = family == 1 and { family = family, path = '/tmp/fibers.sock' }
      or { family = family, addr = family == 10 and '::1' or '127.0.0.1', port = 43000 + next_fd }
    return next_fd
  end
  function socket_mod.setsockopt(_fd, _level, _option, value)
    assert_eq(type(value), 'number', 'luaposix socket option value type')
    assert_eq(value, 1, 'luaposix enabled socket option value')
    return 0
  end
  function socket_mod.bind(fd, address)
    local copy = {}
    for key, value in pairs(address) do copy[key] = value end
    if copy.port == 0 then copy.port = 43000 + fd end
    local_by_fd[fd] = copy
    return 0
  end
  function socket_mod.listen() return 0 end
  function socket_mod.getsockname(fd) return local_by_fd[fd] end
  function socket_mod.getpeername(fd) return peer_by_fd[fd] end
  function socket_mod.accept(fd)
    local accepted = fd + 100
    local family = local_by_fd[fd].family
    local_by_fd[accepted] = family == 1 and { family = family, path = '/tmp/fibers.sock' }
      or { family = family, addr = family == 10 and '::1' or '127.0.0.1', port = 43001 }
    peer_by_fd[accepted] = family == 1 and { family = family, path = '' }
      or { family = family, addr = family == 10 and '::1' or '127.0.0.1', port = 43002 }
    return accepted, peer_by_fd[accepted]
  end
  function socket_mod.connect(fd, address) peer_by_fd[fd] = address; return nil, 'in progress', 115 end
  function socket_mod.getsockopt() return 0 end
  function socket_mod.getaddrinfo(host, service, hints)
    assert_eq(host, 'localhost')
    assert_eq(service, '80')
    assert_eq(hints.socktype, socket_mod.SOCK_STREAM)
    return {
      { family = socket_mod.AF_INET, addr = '127.0.0.1', port = 80 },
      { family = socket_mod.AF_INET, addr = '127.0.0.1', port = 80 },
    }
  end
  local fd_stub = {
    is_supported = function() return true end,
    new = function(fd) return numeric_handle(fd) end,
  }

  with_modules({
    ['posix.sys.socket'] = function() return socket_mod end,
    ['posix.unistd'] = function() return { close = function() return 0 end, unlink = function() return 0 end } end,
    ['posix.errno'] = function()
      return { EAGAIN = 11, EWOULDBLOCK = 11, EINTR = 4, EINPROGRESS = 115, EALREADY = 114, EISCONN = 106 }
    end,
    ['fibers.host.fd_luaposix'] = function() return fd_stub end,
  }, {
    'posix.sys.socket', 'posix.unistd', 'posix.errno', 'fibers.host.fd_luaposix',
    'fibers.host.socket_luaposix', 'fibers.host.resolver_luaposix', 'fibers.host.luaposix_error',
  }, function()
    local Socket = require('fibers.host.socket_luaposix')
    assert(Socket.supports_ipv4() and Socket.supports_ipv6() and Socket.supports_unix())
    local listener = assert(Socket.create_listener({}, { kind = 'inet4', host = '127.0.0.1', port = 0 }, {}))
    assert(listener:local_address().port > 0)
    local accepted, peer = listener:accept()
    assert(accepted and peer and peer.kind == 'inet4')
    local dial = assert(Socket.start_dial({}, { kind = 'inet4', host = '127.0.0.1', port = 80 }, {
      local_address = { kind = 'inet4', host = '127.0.0.1', port = 0 },
    }))
    assert(dial._connect_pending)
    local connected, connected_peer = dial:finish_connect()
    assert(connected == dial and connected_peer.kind == 'inet4')

    local Resolver = require('fibers.host.resolver_luaposix')
    local addresses = assert(Resolver.resolve({}, { host = 'localhost', service = 80 }, { family = 'inet4' }))
    assert_eq(#addresses, 1, 'luaposix resolver deduplication')
    assert_eq(addresses[1].port, 80)
  end)
end

-- Nixio stream sockets and resolver.
do
  local object_id = 0
  local function object(family)
    object_id = object_id + 1
    local self = { family = family, id = object_id, local_host = family == 'inet6' and '::1' or '127.0.0.1', local_port = 44000 + object_id }
    function self:setblocking(value) assert_eq(value, false); return true end
    function self:setopt(_, _, value) assert_eq(type(value), 'number'); return true end
    function self:bind(host, port) self.local_host, self.local_port = host, port == 0 and (44000 + self.id) or port; return true end
    function self:listen() self.listening = true; return true end
    function self:getsockname() return self.local_host, self.local_port end
    function self:getpeername() return self.peer_host, self.peer_port end
    function self:accept()
      local child = object(self.family)
      child.peer_host, child.peer_port = self.family == 'inet6' and '::1' or '127.0.0.1', 44090
      return child, child.peer_host, child.peer_port
    end
    function self:connect(host, port) self.peer_host, self.peer_port = host, port; return nil, 'in progress', 115 end
    function self:getopt() return 0 end
    function self:close() self.closed = true; return true end
    return self
  end
  local nixio_mod = {
    const = { EAGAIN = 11, EWOULDBLOCK = 11, EINTR = 4, EINPROGRESS = 115, EALREADY = 114, EISCONN = 106 },
    socket = function(family, kind) assert_eq(kind, 'stream'); return object(family) end,
    pipe = function() return {}, {} end,
    errno = function() return 0 end,
    strerror = function(n) return 'errno ' .. tostring(n) end,
    getaddrinfo = function(host, family, service)
      assert_eq(host, 'localhost'); assert_eq(family, 'inet'); assert_eq(service, '80')
      return {
        { family = 'inet', address = '127.0.0.1', port = 80 },
        { family = 'inet', address = '127.0.0.1', port = 80 },
      }
    end,
  }
  local fd_stub = {
    is_supported = function() return true end,
    new = function(obj)
      local handle = numeric_handle(obj.id)
      handle.obj = obj
      handle._close = function(self) return self.obj:close() end
      return handle
    end,
  }

  with_modules({
    nixio = function() return nixio_mod end,
    ['fibers.host.fd_nixio'] = function() return fd_stub end,
  }, {
    'nixio', 'fibers.host.fd_nixio', 'fibers.host.socket_nixio', 'fibers.host.resolver_nixio',
    'fibers.host.nixio_error',
  }, function()
    local Socket = require('fibers.host.socket_nixio')
    assert(Socket.supports_ipv4() and Socket.supports_ipv6() and Socket.supports_unix())
    local listener = assert(Socket.create_listener({}, { kind = 'inet4', host = '127.0.0.1', port = 0 }, {}))
    assert(listener:local_address().port > 0)
    local accepted, peer = listener:accept()
    assert(accepted and peer and peer.kind == 'inet4')
    assert(accepted.readable and accepted.writable, 'Nixio accepted socket should receive initial readiness hints')
    local dial = assert(Socket.start_dial({}, { kind = 'inet4', host = '127.0.0.1', port = 80 }, {
      local_address = { kind = 'inet4', host = '127.0.0.1', port = 0 },
    }))
    assert(dial._connect_pending)
    local connected, connected_peer = dial:finish_connect()
    assert(connected == dial and connected_peer.kind == 'inet4')
    assert(dial.readable and dial.writable, 'Nixio connected socket should receive initial readiness hints')

    local Resolver = require('fibers.host.resolver_nixio')
    local addresses = assert(Resolver.resolve({}, { host = 'localhost', service = 80 }, { family = 'inet4' }))
    assert_eq(#addresses, 1, 'Nixio resolver deduplication')
    assert_eq(addresses[1].port, 80)
  end)
end

print('tests/embedding/test_socket_resolver_optional_providers.lua: ok')
