package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function with_modules(preloads, cleared, fn)
  local saved_preload = {}
  local saved_loaded = {}
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
  for name, loader in pairs(saved_preload) do
    package.preload[name] = loader
  end
  for i = 1, #cleared do
    local name = cleared[i]
    package.loaded[name] = saved_loaded[name]
  end
  assert(ok, err)
end

-- Exercise the luaposix adapter without requiring the optional native module.
do
  local recv_limit
  local sent
  local socket_mod = {
    AF_INET = 2,
    AF_INET6 = 10,
    SOCK_DGRAM = 2,
    SOL_SOCKET = 1,
    SO_REUSEADDR = 2,
    socket = function()
      return 41
    end,
    bind = function()
      return 0
    end,
    setsockopt = function(_fd, _level, _option, value)
      assert_eq(type(value), 'number', 'luaposix datagram option value type')
      assert_eq(value, 1, 'luaposix enabled datagram option value')
      return 0
    end,
    getsockname = function()
      return { family = 2, addr = '127.0.0.1', port = 41000 }
    end,
    recvfrom = function(_fd, limit)
      recv_limit = limit
      return 'data', { family = 2, addr = '127.0.0.2', port = 53 }
    end,
    sendto = function(_fd, data, target)
      sent = { data = data, target = target }
      return #data
    end,
  }
  local fd_stub = {
    is_supported = function()
      return true
    end,
    new = function(fd)
      return {
        fd = fd,
        clear_readable = function() end,
        clear_writable = function() end,
        close = function()
          return true
        end,
      }
    end,
  }

  with_modules({
    ['posix.sys.socket'] = function()
      return socket_mod
    end,
    ['posix.unistd'] = function()
      return {
        close = function()
          return 0
        end,
      }
    end,
    ['posix.errno'] = function()
      return { EAGAIN = 11, EWOULDBLOCK = 11, EMSGSIZE = 90 }
    end,
    ['fibers.host.fd_luaposix'] = function()
      return fd_stub
    end,
  }, {
    'posix.sys.socket',
    'posix.unistd',
    'posix.errno',
    'fibers.host.fd_luaposix',
    'fibers.host.datagram_luaposix',
  }, function()
    local Provider = require('fibers.host.datagram_luaposix')
    assert(Provider.is_supported())
    local handle = assert(Provider.create_datagram({}, {
      kind = 'inet4',
      host = '127.0.0.1',
      port = 0,
    }, {}))
    assert_eq(handle:local_address().port, 41000)
    local packet = assert(handle:recv_from(1200))
    assert_eq(recv_limit, 1200)
    assert_eq(packet.data, 'data')
    assert_eq(packet.peer.host, '127.0.0.2')
    assert(packet.flags.truncation_unknown == true)
    assert_eq(packet.flags.receive_limit, 1200)
    assert_eq(
      handle:send_to('query', {
        kind = 'inet4',
        host = '127.0.0.2',
        port = 53,
      }),
      5
    )
    assert_eq(sent.data, 'query')
    assert_eq(sent.target.port, 53)
  end)
end

-- Exercise the Nixio object adapter and its fixed receive-buffer limitation.
do
  local recv_limit
  local send_call
  local object = {}
  function object:setblocking(value)
    assert_eq(value, false)
    return true
  end
  function object:setopt(_, _, value)
    assert_eq(type(value), 'number')
    return true
  end
  function object:bind()
    return true
  end
  function object:getsockname()
    return '::1', 42000
  end
  function object:recvfrom(limit)
    recv_limit = limit
    return 'four', '::2', 53
  end
  function object:sendto(data, host, port, offset, length)
    send_call = { data, host, port, offset, length }
    return length
  end
  function object:close()
    return true
  end

  local nixio_mod = {
    const = {
      EAGAIN = 11,
      EWOULDBLOCK = 11,
      EMSGSIZE = 90,
      buffersize = 4,
    },
    socket = function(family, kind)
      assert_eq(family, 'inet6')
      assert_eq(kind, 'dgram')
      return object
    end,
    errno = function()
      return 0
    end,
    strerror = function(number)
      return 'errno ' .. tostring(number)
    end,
  }
  local fd_stub = {
    is_supported = function()
      return true
    end,
    new = function(value)
      return {
        obj = value,
        clear_readable = function() end,
        clear_writable = function() end,
        close = function()
          return true
        end,
      }
    end,
  }

  with_modules({
    nixio = function()
      return nixio_mod
    end,
    ['fibers.host.fd_nixio'] = function()
      return fd_stub
    end,
  }, {
    'nixio',
    'fibers.host.fd_nixio',
    'fibers.host.datagram_nixio',
  }, function()
    local Provider = require('fibers.host.datagram_nixio')
    assert(Provider.is_supported())
    local handle = assert(Provider.create_datagram({}, {
      kind = 'inet6',
      host = '::1',
      port = 0,
      scope_id = 0,
      flowinfo = 0,
    }, {}))
    assert_eq(handle:local_address().port, 42000)
    local packet = assert(handle:recv_from(4096))
    assert_eq(recv_limit, 4)
    assert_eq(packet.data, 'four')
    assert(packet.flags.truncation_unknown == true)
    assert_eq(packet.flags.receive_limit, 4)
    assert_eq(
      handle:send_to('dns', {
        kind = 'inet6',
        host = '::2',
        port = 53,
        scope_id = 0,
        flowinfo = 0,
      }),
      3
    )
    assert_eq(send_call[1], 'dns')
    assert_eq(send_call[2], '::2')
    assert_eq(send_call[3], 53)
    assert_eq(send_call[4], 0)
    assert_eq(send_call[5], 3)
  end)
end

print('tests/embedding/test_datagram_optional_providers.lua: ok')
