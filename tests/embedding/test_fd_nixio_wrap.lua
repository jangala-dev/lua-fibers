package.path = table.concat(
  { './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/?.lua', package.path },
  ';'
)

local saved_nixio = package.loaded.nixio
local saved_host = package.loaded['fibers.host.nixio']
local saved_provider = package.loaded['fibers.host.provider.nixio']
local next_fd = 10
local function object()
  next_fd = next_fd + 1
  local value = { id = next_fd, blocking = true }
  function value:fileno()
    return self.id
  end
  function value:setblocking(blocking)
    self.blocking = blocking
    return true
  end
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
  function value:shutdown()
    error('simulated Nixio shutdown variation')
  end
  return value
end
local nixio = {
  const = { EAGAIN = 11, EWOULDBLOCK = 11, EINTR = 4 },
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
    return object(), object()
  end,
  errno = function()
    return 0
  end,
  strerror = function(number)
    return 'errno ' .. tostring(number)
  end,
}
package.loaded.nixio, package.loaded['fibers.host.nixio'], package.loaded['fibers.host.provider.nixio'] =
  nixio, nil, nil
local ok, err = pcall(function()
  local provider = require('fibers.host.provider.nixio')
  local host = require('fibers.host.nixio').new()
  local raw = object()
  local handle = assert(host.fd.new(raw, { host = host }))
  assert(provider.poll.key(raw) == raw)
  assert(provider.poll.key(handle:readiness_key()) == raw)
  assert(handle.obj == raw and handle.fd == raw.id and raw.blocking == false)
  assert(handle:shutdown_read() and handle:shutdown_write())
  assert(handle:close() and raw.closed)
  host:close()
end)
package.loaded.nixio, package.loaded['fibers.host.nixio'], package.loaded['fibers.host.provider.nixio'] =
  saved_nixio, saved_host, saved_provider
assert(ok, err)
return true
