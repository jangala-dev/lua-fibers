local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local file = require('fibers.file')
local AutoIO = require('fibers.io.auto')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')
local MemoryProvider = require('fibers.file.memory_provider')

local tests = {}

local function assert_write_all(handle, bytes, label)
  local offset = 1
  while offset <= #bytes do
    local written, err = handle:write(bytes:sub(offset))
    assert(
      type(written) == 'number' and written > 0,
      (label or 'file write') .. ': ' .. tostring(err or ('zero progress at byte ' .. tostring(offset)))
    )
    assert(
      written <= #bytes - offset + 1,
      (label or 'file write') .. ': provider reported an oversized write'
    )
    offset = offset + written
  end
  return #bytes
end

local function tmp_path(label)
  return (os.tmpname() .. '-' .. tostring(label or 'file'))
end

local function memory_provider(initial)
  local provider = { name = 'memory-file', paths = initial or {}, directories = {} }
  local Backend = {}
  Backend.__index = Backend

  local function content(self)
    return self.provider.paths[self.path] or ''
  end
  function Backend:read(count)
    local data = content(self)
    if self.position >= #data then
      return ''
    end
    if self.provider.max_read then
      count = math.min(count, self.provider.max_read)
    end
    local out = data:sub(self.position + 1, self.position + count)
    self.position = self.position + #out
    return out
  end
  function Backend:read_line(keep)
    local data = content(self)
    if self.position >= #data then
      return nil
    end
    local nl = data:find('\n', self.position + 1, true)
    local last = nl and (nl - 1) or #data
    local out = data:sub(self.position + 1, last)
    self.position = nl and nl or #data
    if nl and keep then
      out = out .. '\n'
    end
    return out
  end
  function Backend:write(bytes)
    if self.provider.max_write and #bytes > self.provider.max_write then
      bytes = bytes:sub(1, self.provider.max_write)
    end
    local data = content(self)
    local before = data:sub(1, self.position)
    local after = data:sub(self.position + #bytes + 1)
    self.provider.paths[self.path] = before .. bytes .. after
    self.position = self.position + #bytes
    return #bytes
  end
  function Backend:seek(whence, offset)
    local base = whence == 'set' and 0 or (whence == 'end' and #content(self) or self.position)
    local next_position = base + offset
    if next_position < 0 then
      return nil, HostError.invalid_argument('file', 'seek')
    end
    self.position = next_position
    return next_position
  end
  function Backend:flush()
    self.provider.flushes = (self.provider.flushes or 0) + 1
    return true
  end
  function Backend:sync(data_only)
    self.provider.syncs = (self.provider.syncs or 0) + 1
    self.provider.last_data_only = data_only
    return true
  end
  function Backend:close()
    self.closed = true
    return true
  end

  function provider:is_supported()
    return true
  end
  function provider:open(path, mode, opts)
    opts = opts or {}
    self.last_open_opts = opts
    if opts.exclusive and self.paths[path] ~= nil then
      return nil, HostError.system('file', 'open', 'exists', 'EEXIST')
    end
    if mode:sub(1, 1) == 'r' and self.paths[path] == nil then
      return nil, HostError.system('file', 'open', 'not found', 'ENOENT', nil, { path = path })
    end
    if mode:sub(1, 1) == 'w' then
      self.paths[path] = ''
    end
    if self.paths[path] == nil then
      self.paths[path] = ''
    end
    local position = mode:sub(1, 1) == 'a' and #self.paths[path] or 0
    return setmetatable({ provider = self, path = path, position = position, closed = false }, Backend)
  end
  function provider:rename(from, to)
    if self.paths[from] == nil then
      return nil, HostError.system('file', 'rename', 'not found', 'ENOENT')
    end
    self.paths[to], self.paths[from] = self.paths[from], nil
    return true
  end
  function provider:unlink(path)
    if self.paths[path] == nil then
      return nil, HostError.system('file', 'unlink', 'not found', 'ENOENT')
    end
    self.paths[path] = nil
    return true
  end
  function provider:mkdir(path, opts)
    self.last_mkdir_opts = opts
    self.directories[path] = true
    return true
  end
  function provider:mkdir_p(path, opts)
    self.last_mkdir_opts = opts
    self.directories[path] = true
    return true
  end
  return provider
end

local function host_with_provider(provider)
  local host = SimulatedHost.new({ auto_advance_time = true })
  function host:file_provider()
    return provider
  end
  return host
end

function tests.file_api_requires_running_scope()
  local ok, err = pcall(file.open, '/tmp/not-opened', 'rb')
  assert(ok == false)
  assert(tostring(err):match('running Fibers scope') or tostring(err):match('current Scope'))
end

function tests.evented_regular_file_round_trip()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/config', 'w+b', {}))
    assert(opened:is_file())
    assert(opened:filename() == '/config')
    assert(opened:write('alpha', 123) == 8)
    assert(opened:flush())
    assert(opened:seek('set', 0) == 0)
    assert(opened:read(5) == 'alpha')
    assert(opened:read_all({ max = 8 }) == '123')
    assert(opened:close())

    assert(file.read_all('/config', { max = 16 }) == 'alpha123')
    assert(file.rename('/config', '/renamed', {}))
    assert(file.unlink('/renamed', {}))
    assert(file.mkdir('/directory', {}))
    assert(file.mkdir_p('/directory/a/b', {}))
  end, { host = host_with_provider(provider) })
end

function tests.file_ops_return_values_and_submissions_are_explicit()
  local provider = memory_provider({ ['/x'] = 'value' })
  fibers.run(function()
    assert(fibers.perform(file.read_all_op('/x', { max = 32 })) == 'value')
    local job = fibers.perform(file.submit_read_all_op('/x', { max = 32 }))
    assert(job and fibers.perform(job:result_op()) == 'value')

    local opened = assert(file.open('/x', 'rb', {}))
    assert(fibers.perform(opened:read_op(2)) == 'va')
    assert(opened:seek('set', 0) == 0)
    local request = fibers.perform(opened:submit_read_op(2))
    assert(request and fibers.perform(request:result_op()) == 'va')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.read_line_eof_is_successful_nil()
  local provider = memory_provider({ ['/lines'] = 'one\n' })
  fibers.run(function()
    local opened = assert(file.open('/lines', 'rb', {}))
    assert(opened:read_line() == 'one')
    local value, err = opened:read_line()
    assert(value == nil)
    assert(err == nil)
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.bounded_handle_read_restores_position()
  local provider = memory_provider({ ['/bounded'] = 'abcdef' })
  fibers.run(function()
    local opened = assert(file.open('/bounded', 'rb', {}))
    local value, err = opened:read_all({ max = 3, chunk_size = 2 })
    assert(value == nil)
    assert(HostError.is(err, 'system'))
    assert(opened:read(3) == 'def')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.append_and_read_limit_validation()
  local provider = memory_provider({ ['/append'] = 'a' })
  fibers.run(function()
    assert(file.write_all('/append', 'b', { append = true }) == 1)
    assert(file.read_all('/append', {}) == 'ab')
    local ok = pcall(file.read_all, '/append', { max = -1 })
    assert(ok == false)
    ok = pcall(file.read_all, '/append', { chunk_size = 0 })
    assert(ok == false)
  end, { host = host_with_provider(provider) })
end

function tests.write_all_retries_partial_writes()
  local provider = memory_provider()
  provider.max_write = 2
  fibers.run(function()
    assert(file.write_all('/partial', 'abcdef', {}) == 6)
    assert(file.read_all('/partial', { max = 16 }) == 'abcdef')
  end, { host = host_with_provider(provider) })
end

function tests.queued_operations_preserve_order_and_close_is_idempotent()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/ordered', 'w+b', {}))
    local write_a = fibers.perform(opened:submit_write_op('abc'))
    local seek_middle = fibers.perform(opened:submit_seek_op('set', 1))
    local write_z = fibers.perform(opened:submit_write_op('Z'))
    local rewind = fibers.perform(opened:submit_seek_op('set', 0))
    local read_back = fibers.perform(opened:submit_read_op(3))

    -- Await the last request first: completion still reflects admission order.
    assert(read_back:result() == 'aZc')
    assert(write_a:result() == 3)
    assert(seek_middle:result() == 1)
    assert(write_z:result() == 1)
    assert(rewind:result() == 0)

    assert(opened:close())
    assert(opened:close())
    local value, err = opened:read(1)
    assert(value == nil)
    assert(HostError.is(err, 'closed'))
  end, { host = host_with_provider(provider) })
end

function tests.zero_length_and_line_boundaries()
  local long_line = string.rep('x', 1024)
  local provider = memory_provider({ ['/lines'] = 'first\n' .. long_line })
  fibers.run(function()
    local opened = assert(file.open('/lines', 'r+b', {}))
    assert(opened:read(0) == '')
    assert(opened:write('') == 0)
    assert(opened:read_line(true) == 'first\n')
    assert(opened:read_line() == long_line)
    local value, err = opened:read_line()
    assert(value == nil and err == nil)
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.read_exactly_loops_and_reports_short_eof()
  local provider = memory_provider({ ['/exact'] = 'abcdef' })
  provider.max_read = 2
  fibers.run(function()
    local opened = assert(file.open('/exact', 'rb', {}))
    assert(opened:read_exactly(5) == 'abcde')
    local value, err = opened:read_exactly(2)
    assert(value == nil)
    assert(HostError.is(err, 'eof'))
    assert(err.expected == 2 and err.received == 1)
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.flush_sync_and_permissions_are_distinct()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/durable', 'w+b', { permissions = 384 }))
    assert(provider.last_open_opts.permissions == 384)
    assert(opened:write('x') == 1)
    assert(opened:flush())
    assert(opened:sync({ data_only = true }))
    assert(provider.flushes == 1)
    assert(provider.syncs == 1 and provider.last_data_only == true)
    assert(opened:close())
    assert(file.mkdir('/private', { permissions = 448 }))
    assert(provider.last_mkdir_opts.permissions == 448)
  end, { host = host_with_provider(provider) })
end

function tests.temporary_files_unlink_or_persist_after_rename()
  local provider = MemoryProvider.new()
  fibers.run(function()
    local temporary = assert(file.tmpfile({ directory = '/tmp', prefix = 'test-' }))
    local temporary_path = temporary:filename()
    assert(provider.paths[temporary_path] ~= nil)
    assert(temporary:write('discard') == 7)
    assert(temporary:close())
    assert(provider.paths[temporary_path] == nil)

    local persisted = assert(file.tmpfile({ directory = '/tmp', prefix = 'test-' }))
    assert(persisted:write('keep') == 4)
    assert(persisted:rename('/saved'))
    assert(persisted:close())
    assert(file.read_all('/saved', { max = 16 }) == 'keep')
  end, { host = host_with_provider(provider) })
end

function tests.memory_provider_keeps_open_inode_after_rename_and_unlink()
  local provider = MemoryProvider.new({ files = { ['/old'] = 'abc' } })
  fibers.run(function()
    local first = assert(file.open('/old', 'r+b', {}))
    local second = assert(file.open('/old', 'rb', {}))
    assert(first:rename('/new'))
    assert(file.unlink('/new', {}))
    assert(first:seek('end', 0) == 3)
    assert(first:write('d') == 1)
    assert(second:seek('set', 0) == 0)
    assert(second:read_exactly(4) == 'abcd')
    assert(first:close())
    assert(second:close())
  end, { host = host_with_provider(provider) })
end

function tests.file_close_waits_for_private_lifetime_descendants()
  local provider = memory_provider()
  local original_open = provider.open
  local child_finished = false

  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then
      return nil, err
    end
    local original_close = backend.close
    function backend:close(reason)
      fibers.spawn(function()
        Sleep.sleep(0.01)
        child_finished = true
      end, 'file-close-descendant')
      return original_close(self, reason)
    end
    return backend
  end

  local result = fibers.try_run(function()
    local opened = assert(file.open('/joined-close', 'w+b', {}))
    assert(opened:close())
    assert(child_finished, 'File:close returned before its private Lifetime descendants settled')
  end, { host = host_with_provider(provider) })

  assert(result.ok, result:tostring())
end

function tests.file_driver_does_not_stop_other_fibres()
  local provider = memory_provider({ ['/slow'] = 'ready' })
  local original_open = provider.open
  function provider:open(path, mode, opts)
    opts = opts or {}
    self.last_open_opts = opts
    if opts.exclusive and self.paths[path] ~= nil then
      return nil, HostError.system('file', 'open', 'exists', 'EEXIST')
    end
    Sleep.sleep(0.02)
    return original_open(self, path, mode)
  end
  fibers.run(function()
    local ticked = false
    local task = fibers.spawn(function()
      Sleep.sleep(0.005)
      ticked = true
    end, 'file-ticker')
    assert(file.read_all('/slow', {}) == 'ready')
    task:await()
    assert(ticked)
  end, { host = host_with_provider(provider) })
end

function tests.runtime_closes_selected_file_provider_once()
  local provider = memory_provider()
  provider.shutdowns = 0
  function provider:shutdown()
    self.shutdowns = self.shutdowns + 1
    return true
  end
  local host = SimulatedHost.new({ auto_advance_time = true })
  function host:file_provider()
    return provider
  end
  local result = fibers.try_run(function()
    assert(file.mkdir('/runtime-owned'))
  end, { host = host })
  assert(result.ok, result:tostring())
  assert(provider.shutdowns == 1)
end

function tests.worker_file_provider_is_evented()
  local host = AutoIO.default()
  if not (host.capabilities and host.capabilities.process) then
    if host.close then
      host:close()
    end
    return
  end
  local path = tmp_path('worker-evented')
  local raw = assert(io.open(path, 'wb'))
  assert(raw:write('worker'))
  assert(raw:close())
  local Worker = require('fibers.file.worker_provider')
  function host:file_provider(runtime)
    return Worker.new(runtime, { worker_script = './tests/support/file_worker_delayed.lua' })
  end
  local result = fibers.try_run(function()
    local ticked = false
    local ticker = fibers.spawn(function()
      Sleep.sleep(0.005)
      ticked = true
    end, 'file-worker-ticker')
    assert(file.read_all(path, { max = 32 }) == 'worker')
    ticker:await()
    assert(ticked)
  end, { host = host })
  if host.close then
    host:close()
  end
  pcall(os.remove, path)
  assert(result.ok, result:tostring())
end

function tests.native_evented_file_provider_when_available()
  local host = AutoIO.default()
  if not (host.capabilities and host.capabilities.file) then
    if host.close then
      host:close()
    end
    return
  end
  local path = tmp_path('native-evented')
  local directory = tmp_path('native-directory')
  pcall(os.remove, path)
  pcall(os.remove, directory)
  local result = fibers.try_run(function()
    local opened, err = file.open(path, 'w+b')
    assert(opened, tostring(err))
    assert(assert_write_all(opened, 'native', 'native file write') == 6)
    assert(opened:seek('set', 0) == 0)
    assert(opened:read(6) == 'native')
    local synced, sync_err = opened:sync()
    assert(synced or HostError.is_unsupported(sync_err), tostring(sync_err))
    assert(opened:close())
    assert(file.read_all(path, { max = 32 }) == 'native')
    assert(file.unlink(path))

    assert(file.mkdir(directory, { permissions = 448 }))

    local temporary, temp_err = file.tmpfile({ prefix = 'fibers-native-' })
    if temporary then
      local temporary_path = temporary:filename()
      assert(assert_write_all(temporary, 'temporary', 'temporary file write') == 9)
      assert(temporary:close())
      local reopened = file.open(temporary_path, 'rb')
      assert(reopened == nil)
    else
      assert(HostError.is_unsupported(temp_err), tostring(temp_err))
    end
  end, { host = host })
  if host.close then
    host:close()
  end
  pcall(os.remove, path)
  pcall(os.remove, directory)
  assert(result.ok, result:tostring())
end

local names = {}
for name in pairs(tests) do
  names[#names + 1] = name
end
table.sort(names)
for i = 1, #names do
  tests[names[i]]()
end

print('tests/io/test_file.lua: ok')
