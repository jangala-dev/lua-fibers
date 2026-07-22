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

-- Nixio is sufficient to verify the opaque-handle datagram path; the numeric
-- path is covered by the native Linux provider matrix.
do
  local object = { id = 9, blocking = true }
  function object:fileno()
    return self.id
  end
  function object:setblocking(value)
    self.blocking = value
    return true
  end
  function object:setopt()
    return true
  end
  function object:bind()
    return true
  end
  function object:getsockname()
    return '::1', 42000
  end
  function object:recvfrom(limit)
    self.limit = limit
    return 'four', '::2', 53
  end
  function object:sendto(data, host, port, offset, length)
    self.sent = { data, host, port, offset, length }
    return length
  end
  function object:read()
    return ''
  end
  function object:write(bytes)
    return #bytes
  end
  function object:close()
    self.closed = true
    return true
  end
  local nixio = {
    const = { EINTR = 4, EAGAIN = 11, EWOULDBLOCK = 11, EMSGSIZE = 90, buffersize = 4 },
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
      return object, object
    end,
    socket = function(family, kind)
      assert(family == 'inet6' and kind == 'dgram')
      return object
    end,
    errno = function()
      return 0
    end,
    strerror = function(number)
      return 'errno ' .. tostring(number)
    end,
  }
  with_modules({
    nixio = function()
      return nixio
    end,
  }, { 'nixio', 'fibers.host.nixio', 'fibers.host.provider.nixio' }, function()
    local host = require('fibers.host.nixio').new()
    local datagram =
      assert(host:create_datagram({ kind = 'inet6', host = '::1', port = 0, scope_id = 0, flowinfo = 0 }, {}))
    local packet = assert(datagram:recv_from(4096))
    assert(object.limit == 4 and packet.data == 'four' and packet.peer.host == '::2')
    assert(packet.flags.truncation_unknown and packet.flags.receive_limit == 4)
    assert(
      datagram:send_to('dns', { kind = 'inet6', host = '::2', port = 53, scope_id = 0, flowinfo = 0 }) == 3
    )
    datagram:close()
    host:close()
  end)
end

print('tests/embedding/test_datagram_optional_providers.lua: ok')
