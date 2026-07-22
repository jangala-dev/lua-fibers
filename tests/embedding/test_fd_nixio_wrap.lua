package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Exercise the Nixio wrapper independently of an installed Nixio module.  This
-- guards the wrapper path itself; the native host matrix separately exercises
-- real Nixio pipe objects when available.
local saved_preload = package.preload.nixio
local saved_nixio = package.loaded.nixio
local saved_fd = package.loaded['fibers.host.fd_nixio']
local saved_error = package.loaded['fibers.host.nixio_error']

local setblocking_arg
local closed = false

package.preload.nixio = function()
  return {
    pipe = function()
      return nil, nil
    end,
    const = {
      EAGAIN = 11,
      EWOULDBLOCK = 11,
    },
    errno = function()
      return 5 -- deliberately stale: explicit "Success" must still mean no error
    end,
    strerror = function(errno)
      return errno == 0 and 'Success' or ('errno ' .. tostring(errno))
    end,
  }
end
package.loaded.nixio = nil
package.loaded['fibers.host.fd_nixio'] = nil
package.loaded['fibers.host.nixio_error'] = nil

local ok, err = pcall(function()
  local Fd = require('fibers.host.fd_nixio')
  local object = {}

  function object:fileno()
    return 42
  end

  function object:setblocking(value)
    setblocking_arg = value
    return true
  end

  function object:read(_max)
    return nil, 'Success'
  end

  function object:write(bytes)
    return #bytes
  end

  function object:close()
    closed = true
    return true
  end

  assert(Fd.wrap == nil, 'new has no wrap alias')
  local handle, wrap_err = Fd.new(object, { name = 'fake-nixio-handle' })
  assert(handle, tostring(wrap_err))
  assert(handle.obj == object)
  assert(handle.fd == 42)
  assert(setblocking_arg == false, 'Nixio handles should be placed in non-blocking mode')
  local data, read_err = handle:read(1)
  local HostError = require('fibers.host.error')
  assert(data == nil and HostError.is_eof(read_err), 'Nixio Success return should be EOF')
  assert(handle:close())
  assert(closed)
end)

package.preload.nixio = saved_preload
package.loaded.nixio = saved_nixio
package.loaded['fibers.host.fd_nixio'] = saved_fd
package.loaded['fibers.host.nixio_error'] = saved_error

assert(ok, err)
print('tests/embedding/test_fd_nixio_wrap.lua: ok')
