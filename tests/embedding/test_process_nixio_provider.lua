package.path = table.concat(
  { './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/?.lua', package.path },
  ';'
)

local saved = {}
for _, name in ipairs({ 'nixio', 'nixio.fs', 'fibers.host.nixio' }) do
  saved[name] = package.loaded[name]
  package.loaded[name] = nil
end

local next_fd, pipe_payloads, signals = 40, {}, {}
local function file(payload)
  next_fd = next_fd + 1
  local value = { id = next_fd, buffer = payload or '', closed = false, blocking = true }
  function value:fileno()
    return self.id
  end
  function value:setblocking(blocking)
    self.blocking = blocking
    return true
  end
  function value:read(maximum)
    if self.closed then
      return nil, 9, 'closed'
    end
    if self.buffer == '' then
      return ''
    end
    local out = self.buffer:sub(1, maximum)
    self.buffer = self.buffer:sub(#out + 1)
    return out
  end
  function value:write(bytes, offset, length)
    if self.closed then
      return nil, 9, 'closed'
    end
    offset, length = offset or 0, length or (#bytes - (offset or 0))
    self.written = (self.written or '') .. bytes:sub(offset + 1, offset + length)
    return length
  end
  function value:close()
    self.closed = true
    return true
  end
  return value
end

local fake_nixio = {
  const = {
    ENOENT = 2,
    EAGAIN = 11,
    EWOULDBLOCK = 11,
    EINTR = 4,
    SIGTERM = 15,
    SIGKILL = 9,
    buffersize = 512,
  },
  stdin = file(),
  stdout = file(),
  stderr = file(),
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
  errno = function()
    return 2
  end,
  strerror = function(number)
    return number == 2 and 'not found' or ('errno ' .. tostring(number))
  end,
  fork = function()
    return 700
  end,
  waitpid = function(pid, flag)
    assert(pid == 700 and flag == 'nohang')
    return 700, 'exited', 0
  end,
  exece = function() end,
  pipe = function()
    return file(table.remove(pipe_payloads, 1) or ''), file()
  end,
  open = function()
    return file()
  end,
  dup = function()
    return file()
  end,
  kill = function(pid, signal)
    signals[#signals + 1] = { pid = pid, signal = signal }
    return true
  end,
  chdir = function()
    return true
  end,
  getcwd = function()
    return '/work'
  end,
  getenv = function()
    return { PATH = '/bin:/usr/bin', HOME = '/home/test' }
  end,
  setsid = function()
    return 1
  end,
}
local fake_fs = {
  access = function(path)
    return path == '/bin/sh' or path == '/work/bin/tool' or nil, 2, 'not found'
  end,
  stat = function(path, field)
    if path == '/work' and field == 'type' then
      return 'dir'
    end
    return nil, 2, 'not found'
  end,
}
package.loaded.nixio, package.loaded['nixio.fs'] = fake_nixio, fake_fs

local ok, err = pcall(function()
  local Host = require('fibers.host.nixio')
  assert(Host.is_supported())
  local host = Host.new()
  local Fd = host.fd

  local raw = file()
  local managed = assert(Fd.new(raw, { nonblocking = false }))
  assert(managed.handle == raw)
  assert(managed:close())

  pipe_payloads[#pipe_payloads + 1] = 'pid 321\nexited 0\n'
  local fibers = require('fibers')
  fibers.run(function()
    local process, endpoints = assert(host:start_process({ argv = { 'sh' }, process_group = 'new' }))
    process:bind_runtime(require('fibers.runtime').current())
    assert(next(endpoints) == nil and process:pid() == 321)
    assert(process:signal('term', 'group'))
    assert(#signals == 1 and signals[1].pid == -321 and signals[1].signal == 15)
    assert(fibers.perform(process:open_exit_op(fibers.current_scope())))
    local status = assert(fibers.perform(process:exit_op()))
    assert(status.kind == 'exited' and status.code == 0 and status.success)
    assert(fibers.perform(process:exit_op()) == status)
    assert(process:close())
  end, { host = host })
  host:close()
end)

for name, value in pairs(saved) do
  package.loaded[name] = value
end
assert(ok, err)
return true
