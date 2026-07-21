local saved = {
  nixio = package.loaded.nixio,
  fs = package.loaded['nixio.fs'],
  fd = package.loaded['fibers.host.fd_nixio'],
  process = package.loaded['fibers.host.process_nixio'],
  error = package.loaded['fibers.host.nixio_error'],
}

local next_fd = 40
local pipe_payloads = {}
local signals = {}

local function fake_file(payload)
  next_fd = next_fd + 1
  local fd = next_fd
  return {
    buffer = payload or '',
    closed = false,
    blocking = true,
    fileno = function()
      return fd
    end,
    setblocking = function(self, value)
      self.blocking = value
      return true
    end,
    read = function(self, max)
      if self.closed then
        return nil, 9, 'closed'
      end
      if self.buffer == '' then
        return ''
      end
      local out = self.buffer:sub(1, max)
      self.buffer = self.buffer:sub(#out + 1)
      return out
    end,
    write = function(self, bytes, offset, length)
      if self.closed then
        return nil, 9, 'closed'
      end
      offset = offset or 0
      length = length or (#bytes - offset)
      self.written = (self.written or '') .. bytes:sub(offset + 1, offset + length)
      return length
    end,
    close = function(self)
      self.closed = true
      return true
    end,
  }
end

local fake_nixio = {
  const = { ENOENT = 2, EAGAIN = 11, EWOULDBLOCK = 11, EINTR = 4, SIGTERM = 15, SIGKILL = 9 },
  stdin = fake_file(),
  stdout = fake_file(),
  stderr = fake_file(),
  errno = function()
    return 2
  end,
  strerror = function(eno)
    return eno == 2 and 'not found' or ('errno ' .. tostring(eno))
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
    local payload = table.remove(pipe_payloads, 1) or ''
    return fake_file(payload), fake_file()
  end,
  open = function()
    return fake_file()
  end,
  dup = function()
    return fake_file()
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
    return { PATH = '/bin:/usr/bin', HOME = '/home/test', REMOVE = 'yes' }
  end,
  setsid = function()
    return 1
  end,
}
local fake_fs = {
  access = function(path)
    if path == '/bin/sh' or path == '/work/bin/tool' then
      return true
    end
    return nil, 2, 'not found'
  end,
  stat = function(path, field)
    if path == '/work' and field == 'type' then
      return 'dir'
    end
    return nil, 2, 'not found'
  end,
}

package.loaded.nixio = fake_nixio
package.loaded['nixio.fs'] = fake_fs
package.loaded['fibers.host.fd_nixio'] = nil
package.loaded['fibers.host.process_nixio'] = nil
package.loaded['fibers.host.nixio_error'] = nil

local ok, err = pcall(function()
  local Provider = require('fibers.host.process_nixio')
  local Fd = require('fibers.host.fd_nixio')
  assert(Provider.is_supported())

  local managed_obj = fake_file()
  local managed = assert(Fd.new(managed_obj, { nonblocking = false }))
  local found = false
  for _, obj in ipairs(Fd.open_objects()) do
    if obj == managed_obj then
      found = true
    end
  end
  assert(found)
  assert(managed:close())
  for _, obj in ipairs(Fd.open_objects()) do
    assert(obj ~= managed_obj)
  end

  local std_closed, other_closed = false, false
  Provider._test.close_inherited({
    {
      fileno = function()
        return 2
      end,
      close = function()
        std_closed = true
      end,
    },
    {
      fileno = function()
        return 9
      end,
      close = function()
        other_closed = true
      end,
    },
  })
  assert(std_closed == false and other_closed == true)

  local extended = assert(Provider._test.copy_environment({
    env_mode = 'extend',
    unset_env = { 'REMOVE' },
    env = { EXTRA = 'present' },
  }))
  assert(extended.HOME == '/home/test' and extended.REMOVE == nil and extended.EXTRA == 'present')

  local replaced = assert(Provider._test.copy_environment({
    env_mode = 'replace',
    env = { ONLY = 'value' },
  }))
  assert(replaced.ONLY == 'value' and replaced.HOME == nil)

  local executable = assert(Provider._test.preflight({ argv = { 'sh' } }, extended))
  assert(executable == '/bin/sh')
  local local_executable = assert(Provider._test.preflight({ argv = { 'bin/tool' } }, extended))
  assert(local_executable == '/work/bin/tool')

  local missing, missing_err = Provider._test.preflight({ argv = { 'missing' } }, extended)
  assert(missing == nil and missing_err.action == 'exec')
  local bad_cwd, cwd_err = Provider._test.preflight({ argv = { 'sh' }, cwd = '/missing' }, extended)
  assert(bad_cwd == nil and cwd_err.action == 'chdir')
  local bad_group, group_err = Provider._test.preflight({ argv = { 'sh' }, process_group = 42 }, extended)
  assert(bad_group == nil and group_err.kind == 'unsupported' and group_err.action == 'process_group')
  local bad_fds, fds_err = Provider._test.preflight({ argv = { 'sh' }, pass_fds = { 9 } }, extended)
  assert(bad_fds == nil and fds_err.kind == 'unsupported' and fds_err.action == 'pass_fds')

  assert(Provider._test.parse_startup_line('pid 123', { argv = { 'sh' } }) == 123)
  local failed, failed_err = Provider._test.parse_startup_line('failed cwd 2', { argv = { 'sh' } })
  assert(failed == nil and failed_err.action == 'chdir' and failed_err.number == 2)

  local eof = {
    read = function()
      return nil, nil, 0
    end,
  }
  assert(Provider._test.read_chunk(eof, 64) == '')
  local blocked = {
    read = function()
      return false, nil, 11
    end,
  }
  local blocked_data, blocked_err = Provider._test.read_chunk(blocked, 64)
  assert(blocked_data == nil and blocked_err == 'would_block')

  pipe_payloads[#pipe_payloads + 1] = 'pid 321\nexited 0\n'
  local host_process, endpoints = assert(Provider.start_process({ name = 'mock-nixio' }, {
    argv = { 'sh' },
    process_group = 'new',
  }))
  assert(next(endpoints) == nil)
  assert(host_process:pid() == 321)
  assert(host_process:signal('term', 'group'))
  assert(#signals == 1 and signals[1].pid == -321 and signals[1].signal == 15)
  local status = assert(host_process:reap())
  assert(status.kind == 'exited' and status.code == 0 and status.success == true)
  assert(host_process:reap() == status)
  assert(host_process:close())
end)

package.loaded.nixio = saved.nixio
package.loaded['nixio.fs'] = saved.fs
package.loaded['fibers.host.fd_nixio'] = saved.fd
package.loaded['fibers.host.process_nixio'] = saved.process
package.loaded['fibers.host.nixio_error'] = saved.error

assert(ok, err)
return true
