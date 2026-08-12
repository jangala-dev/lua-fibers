local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local Lifetime = require('fibers.lifetime')
local file = require('fibers.file')
local AutoIO = require('fibers.io.auto')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')
local MemoryProvider = require('tests.support.memory_file_provider')

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

function tests.file_data_ops_are_values_and_control_submissions_are_explicit()
  local provider = memory_provider({ ['/x'] = 'value' })
  fibers.run(function()
    assert(file.read_all('/x', { max = 32 }) == 'value')
    local job = fibers.perform(file.submit_read_all_op('/x', { max = 32 }))
    assert(job and fibers.perform(job:result_op()) == 'value')

    local opened = assert(file.open('/x', 'rb', {}))
    assert(fibers.perform(opened:read_op(2)) == 'va')
    local seek = fibers.perform(opened:submit_seek_op('set', 0))
    assert(seek and fibers.perform(seek:result_op()) == 0)
    assert(fibers.perform(opened:read_op(2)) == 'va')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.regular_file_uses_stream_byte_plane_vocabulary()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/byte-plane', 'w+b', { write_capacity = 2 }))
    local n, rest = fibers.perform(opened:write_some_op('abcd'))
    assert(n == 2 and rest == 'cd')
    assert(opened:flush())
    assert(opened:seek('set', 0) == 0)
    assert(fibers.perform(opened:read_some_op(2)) == 'ab')
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

function tests.bounded_handle_read_failure_is_non_consuming()
  local provider = memory_provider({ ['/bounded'] = 'abcdef' })
  fibers.run(function()
    local opened = assert(file.open('/bounded', 'rb', {}))
    local value, err = opened:read_all({ max = 3 })
    assert(value == nil)
    assert(HostError.is(err, 'system'))
    assert(opened:read(3) == 'abc')
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

function tests.write_all_spans_a_bounded_tx_flow()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/bounded-write', 'wb', { write_capacity = 3 }))
    assert(opened:write_all('abcdefgh') == 8)
    assert(opened:flush())
    assert(opened:close())
    assert(file.read_all('/bounded-write', { max = 16 }) == 'abcdefgh')
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

function tests.buffered_writes_and_control_barriers_preserve_program_order()
  local provider = memory_provider()
  fibers.run(function()
    local opened = assert(file.open('/ordered', 'w+b', {}))
    assert(fibers.perform(opened:write_op('abc')) == 3)

    -- A control submission captures the accepted-byte frontier. Its completion
    -- therefore waits for earlier buffered writes without turning those writes
    -- back into request/completion RPCs.
    local seek_middle = fibers.perform(opened:submit_seek_op('set', 1))
    assert(seek_middle:result() == 1)

    assert(fibers.perform(opened:write_op('Z')) == 1)
    local rewind = fibers.perform(opened:submit_seek_op('set', 0))
    assert(rewind:result() == 0)
    assert(fibers.perform(opened:read_op(3)) == 'aZc')

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


function tests.read_op_races_actual_buffered_bytes_not_host_submission()
  local provider = memory_provider({ ['/slow-read'] = 'payload' })
  local original_open = provider.open
  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then return nil, err end
    local original_read = backend.read
    local first = true
    function backend:read(count)
      if first then
        first = false
        Sleep.sleep(0.02)
      end
      return original_read(self, count)
    end
    return backend
  end

  fibers.run(function()
    local opened = assert(file.open('/slow-read', 'rb', {}))
    local selected = fibers.perform(require('fibers.op').named_choice({
      bytes = opened:read_op(7),
      timeout = Sleep.sleep_op(0.005),
    }))
    assert(selected == 'timeout', 'read_op must wait for bytes, not merely host-read admission')
    assert(opened:read(7) == 'payload')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.seek_cur_reconciles_prefetched_read_ahead()
  local provider = memory_provider({ ['/cursor'] = 'abcdef' })
  fibers.run(function()
    local opened = assert(file.open('/cursor', 'rb', { read_capacity = 32, read_chunk_size = 32 }))
    assert(opened:read(2) == 'ab')
    -- The host backend has read ahead to EOF, but `cur` is the application
    -- cursor after the two bytes actually consumed.
    assert(opened:seek('cur', 1) == 3)
    assert(opened:read(1) == 'd')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.inflight_prefetch_invalidated_by_write_cannot_move_logical_cursor()
  local provider = memory_provider({ ['/stale-read'] = 'abcdef' })
  local original_open = provider.open
  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then return nil, err end
    local original_read = backend.read
    local first = true
    function backend:read(count)
      if first then
        first = false
        Sleep.sleep(0.02)
      end
      return original_read(self, count)
    end
    return backend
  end

  fibers.run(function()
    local opened = assert(file.open('/stale-read', 'r+b', { read_capacity = 32, read_chunk_size = 32 }))
    -- The driver is allowed to have an old-generation prefetch in flight here.
    -- Accepting the write invalidates that generation transactionally.
    assert(fibers.perform(opened:write_op('Z')) == 1)
    assert(opened:flush())
    assert(opened:seek('set', 0) == 0)
    assert(opened:read_exactly(6) == 'Zbcdef')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.write_op_transfers_responsibility_and_flush_reports_host_failure()
  local provider = memory_provider()
  local original_open = provider.open
  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then return nil, err end
    function backend:write(_bytes)
      return nil, HostError.system('file', 'write', 'synthetic write failure', 'EIO', nil, { path = path })
    end
    return backend
  end

  local result = fibers.try_run(function()
    local opened = assert(file.open('/write-failure', 'wb', {}))
    -- Admission to the file-owned TX Flow is the write transaction.
    assert(fibers.perform(opened:write_op('abc')) == 3)
    local ok, err = opened:flush()
    assert(ok == nil)
    assert(HostError.is(err, 'system') and err.code == 'EIO')
    opened:close('write failed')
  end, { host = host_with_provider(provider) })
  -- The failed TX responsibility remains visible when the file Lifetime closes.
  assert(result.ok == false)
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

function tests.memory_provider_zero_fills_sparse_writes()
  local provider = MemoryProvider.new()
  fibers.run(function()
    local opened = assert(file.open('/sparse', 'w+b', {}))
    assert(opened:seek('set', 3) == 3)
    assert(opened:write('x') == 1)
    assert(opened:seek('set', 0) == 0)
    assert(opened:read_exactly(4) == '\0\0\0x')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
end

function tests.thrown_backend_close_is_not_published_as_success()
  local provider = memory_provider()
  local original_open = provider.open
  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then return nil, err end
    function backend:close()
      error('synthetic backend close failure')
    end
    return backend
  end

  local closed, close_err
  local result = fibers.try_run(function()
    local opened = assert(file.open('/close-throws', 'w+b', {}))
    closed, close_err = opened:close()
  end, { host = host_with_provider(provider) })

  assert(closed == nil)
  assert(HostError.is(close_err, 'protocol'))
  assert(result.ok == false)
end

function tests.file_close_waits_for_private_lifetime_descendants()
  local provider = memory_provider()
  local original_open = provider.open
  local child_finished = false

  function provider:open(path, mode, opts)
    local backend, err = original_open(self, path, mode, opts)
    if not backend then return nil, err end
    local original_close = backend.close
    function backend:close(reason)
      fibers.spawn(function()
        Sleep.sleep(0.01)
        child_finished = true
      end):label('file-close-descendant')
      return original_close(self, reason)
    end
    return backend
  end

  local result = fibers.try_run(function()
    local opened = assert(file.open('/joined-close', 'w+b', {}))
    assert(opened:close())
    assert(not child_finished, 'File:close should establish local closure without folding in descendant retirement')
    fibers.perform(Lifetime.of(opened):outcome_op())
    assert(child_finished, 'File Lifetime retirement should account for its private descendants')
  end, { host = host_with_provider(provider) })

  assert(result.ok, result:tostring())
end

function tests.file_driver_does_not_stop_other_fibers()
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
    end):label('file-ticker')
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
  if not (host:supports('process')) then
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
    end):label('file-worker-ticker')
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
  if not (host:supports('file')) then
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


function tests.elastic_whole_byte_facts_are_exact_twins()
  local provider = memory_provider({ ['/bounded-byte-protocol'] = 'abcdefgh' })
  fibers.run(function()
    local opened = assert(file.open('/bounded-byte-protocol', 'r+b', {
      read_capacity = 4,
      read_chunk_size = 2,
      write_capacity = 2,
      write_chunk_size = 2,
    }))

    assert(fibers.perform(opened:read_exactly_op(5)) == 'abcde')
    assert(opened:seek('set', 0) == 0)
    assert(opened:read_exactly(5) == 'abcde')

    assert(opened:seek('set', 0) == 0)
    assert(fibers.perform(opened:read_all_op({ max = 16 })) == 'abcdefgh')
    assert(opened:seek('set', 0) == 0)
    assert(opened:read_all({ max = 16 }) == 'abcdefgh')

    assert(opened:seek('set', 0) == 0)
    local written, write_err = fibers.perform(opened:write_op('WXYZ'))
    assert(written == nil)
    assert(HostError.is(write_err, 'invalid_argument'))
    assert(opened:write_all('WXYZ') == 4)
    assert(opened:flush())
    assert(opened:seek('set', 0) == 0)
    assert(opened:read_exactly(4) == 'WXYZ')
    assert(opened:close())
  end, { host = host_with_provider(provider) })
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
