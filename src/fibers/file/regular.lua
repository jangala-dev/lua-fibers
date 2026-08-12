-- Runtime-only evented file and pipe facilities.
--
-- Regular-file calls are executed by an asynchronous provider. No public file
-- operation is available outside a running Fibers scope.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Completion = require('fibers.resource.completion')
local Flow = require('fibers.resource.flow')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Transfer = require('fibers.io.internal.flow_transfer')
local BytePlane = require('fibers.file.internal.byte_plane')
local FileMode = require('fibers.file.internal.mode')
local IO = require('fibers.io.facility')
local Mailbox = require('fibers.mailbox')
local Protected = require('fibers.protected')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local function provider_open_options(opts)
  return {
    exclusive = opts and opts.exclusive or nil,
    permissions = opts and opts.permissions or nil,
  }
end

local function provider_path_options(action, opts)
  if action == 'mkdir' or action == 'mkdir_p' then
    return { permissions = opts and opts.permissions or nil }
  end
  return nil
end

local Provider = {}

function Provider.for_runtime(runtime, opts)
  if not runtime then
    error('file provider requires a current runtime', 2)
  end
  local cached = runtime._fibers_file_provider
  if cached and (type(cached.is_supported) ~= 'function' or cached:is_supported()) then
    return cached
  end
  runtime._fibers_file_provider = nil

  local host = runtime.host
  if not host or type(host.file_provider) ~= 'function' then
    return nil,
      IOError.unsupported('file', 'provider', {
        host = host and Label.describe(host, host.kind or host.family) or nil,
      })
  end
  local ok, provider = pcall(host.file_provider, host, runtime, opts or {})
  if not ok then error(provider, 0) end
  if provider == nil then
    return nil, IOError.unsupported('file', 'provider', {
      host = Label.describe(host, host.kind or host.family),
    })
  end
  if type(provider) ~= 'table' then
    error('host:file_provider must return a provider table or nil', 2)
  end
  for _, method in ipairs({ 'open', 'rename', 'unlink', 'mkdir' }) do
    if type(provider[method]) ~= 'function' then
      error('file provider must implement ' .. method, 2)
    end
  end
  if provider.is_supported ~= nil then
    if type(provider.is_supported) ~= 'function' then
      error('file provider is_supported must be a function when supplied', 2)
    end
    if not provider:is_supported() then
      return nil, IOError.unsupported('file', 'provider', {
        host = Label.describe(host, host.kind or host.family),
      })
    end
  end

  runtime._fibers_file_provider = provider
  if type(provider.shutdown) == 'function' and type(runtime._add_finalizer) == 'function' then
    runtime:_add_finalizer(function()
      runtime._fibers_file_provider = nil
      return provider:shutdown()
    end)
  end
  return provider
end

local File = {}
local RegularFile = {}
RegularFile.__index = RegularFile
local Command = {}
Command.__index = Command
local Job = {}
Job.__index = Job
local next_file, next_command, next_job, next_temp = 0, 0, 0, 0

local DEFAULT_CHUNK = BytePlane.DEFAULT_CHUNK
local DEFAULT_READ_CAPACITY = 64 * 1024
local DEFAULT_MAX = BytePlane.DEFAULT_MAX
local function validate_path(path, action)
  if type(path) ~= 'string' or path == '' then
    error('file.' .. action .. ' expects a non-empty path string', 3)
  end
  return path
end

local validate_mode = FileMode.require

local function mode_capabilities(mode)
  local parsed = FileMode.parse(mode)
  return parsed.read, parsed.write
end

local validate_read_limits = BytePlane.validate_read_limits

local function validate_capacity(value, default, label)
  if value == nil then return default end
  if type(value) ~= 'number' or value < 1 or value ~= math.floor(value) then
    error(label .. ' must be a positive integer', 3)
  end
  return value
end

local function join_path(directory, name)
  if directory:sub(-1) == '/' then return directory .. name end
  return directory .. '/' .. name
end

local function temp_candidate(opts)
  next_temp = next_temp + 1
  local directory = opts.directory or os.getenv('TMPDIR') or '/tmp'
  local prefix = opts.prefix or 'fibers-'
  local nonce = tostring(os.time())
    .. '-' .. tostring(next_temp) .. tostring(next_temp)
    .. '-' .. tostring(math.random(0, 0x3fffffff))
  return join_path(directory, prefix .. nonce)
end

local function current_runtime(label)
  local rt = Runtime.current()
  if not rt or not Runtime.current_scope() then
    error(label .. ' requires a running Fibers scope', 3)
  end
  return rt
end

local function new_command(kind, args)
  next_command = next_command + 1
  local command = Label.attach(setmetatable({
    kind = kind,
    args = args or {},
    _fibers_id = 'file-command-' .. tostring(next_command),
    completion = Completion.new(),
  }, Command))
  Label.child(command.completion, command, 'completion')
  return command
end

function Command:result_op()
  return self.completion:result_op()
end

local function publish(rt, completion, ok, ...)
  if ok then return IO.masked_perform(rt, completion:publish_success_op(...)) end
  return IO.masked_perform(rt, completion:publish_failure_op((...)))
end

local file_closed_error = BytePlane.closed_error
local normalise_flow_error = BytePlane.normalise_error
local invalidate_read_op = BytePlane.invalidate_read_op

function RegularFile:ready_op()
    return self._ready_completion:result_op()
end

function RegularFile:is_file()
    return true
end

function RegularFile:filename()
    return self._path
end

function RegularFile:closed_op()
  return IO.closed_after_driver_op(self._driver)
end

BytePlane.install(RegularFile)

local function control_submission(file, kind, args, invalidate)
  if file._lifetime:_close_requested() then
    return Op.always(nil, file_closed_error(file, kind))
  end
  local command = new_command(kind, args)
  local prefix = invalidate and invalidate_read_op(file) or Op.always(true)
  return prefix:and_then(file._accepted:read_op()):and_then(Op.guard(function(target)
    local message = { command = command, target = target }
    return file._control_tx:send_op(message):map(function(sent, err)
      if not sent then return nil, normalise_flow_error(file, kind, err) end
      return command
    end)
  end))
end

local function control_result(submission)
  return submission:wrap(function(command, err)
    if not command then return nil, err end
    return command:result()
  end)
end

local function seek_args(whence, offset)
  whence, offset = whence or 'cur', offset or 0
  if whence ~= 'set' and whence ~= 'cur' and whence ~= 'end' then
    error("seek whence must be 'set', 'cur' or 'end'", 3)
  end
  if type(offset) ~= 'number' or offset ~= math.floor(offset) then
    error('seek offset must be an integer', 3)
  end
  return { whence = whence, offset = offset }
end

function RegularFile:submit_seek_op(whence, offset)
  return control_submission(self, 'seek', seek_args(whence, offset), true)
end
function RegularFile:seek_op(whence, offset)
  return control_result(self:submit_seek_op(whence, offset))
end
function RegularFile:submit_flush_op()
  return control_submission(self, 'flush')
end
function RegularFile:flush_op()
  return control_result(self:submit_flush_op())
end
function RegularFile:submit_sync_op(opts)
  return control_submission(self, 'sync', { data_only = opts and opts.data_only == true })
end
function RegularFile:sync_op(opts)
  return control_result(self:submit_sync_op(opts))
end
function RegularFile:submit_rename_op(path)
  return control_submission(self, 'rename', { path = validate_path(path, 'submit_rename_op') })
end
function RegularFile:rename_op(path)
  return control_result(self:submit_rename_op(validate_path(path, 'rename_op')))
end

function RegularFile:close_op(reason)
  if self._lifetime:_close_requested() then return self:closed_op() end
  local command = new_command('close', { reason = reason })
  local close_ops = { invalidate = invalidate_read_op(self) }
  if self._read_flow then
    close_ops.read = self._read_flow:inlet():fail_op(file_closed_error(self, 'read', reason or 'file closing'))
  end
  if self._write_flow then
    close_ops.write = self._write_flow:inlet():close_op(reason or 'file closing')
  end
  return Op.named_each(close_ops)
    :and_then(self._accepted:read_op())
    :and_then(Op.guard(function(target)
      return self._control_tx:send_op({ command = command, target = target })
        :and_then(self._control_tx:close_op(reason or 'file close requested'))
    end))
    :wrap(function()
      local ok, err = command:result()
      if not ok then return nil, err end
      return self:closed()
    end)
end

local function rewind_backend(file, backend)
  local debt = IO.masked_perform(Runtime.current(), file._rewind:read_op())
  if not debt or debt == 0 then return true end
  local pos, err = backend:seek('cur', -debt)
  if pos == nil then return nil, err end
  local consumed, take_err = IO.masked_perform(Runtime.current(), file._rewind:take_op(debt))
  if not consumed then return nil, take_err end
  return true
end

local function fail_write_plane(rt, file, err)
  if file._write_flow then IO.masked_perform(rt, file._write_flow:outlet():fail_op(err)) end
end

local function service_write(file, backend, lease)
  local rt = Runtime.current()
  local rewound, rewind_err = rewind_backend(file, backend)
  if not rewound then
    fail_write_plane(rt, file, rewind_err)
    return nil, rewind_err
  end
  local status, value = Transfer.write_lease(rt, lease, function(bytes) return backend:write(bytes) end)
  if status == 'progress' then
    file._written = file._written + value
    return true
  elseif status == 'would_block' then
    local err = IO.protocol_error('file', 'write', 'completion-driven file backend returned would-block', { path = file._path })
    fail_write_plane(rt, file, err)
    return nil, err
  end
  local err = normalise_flow_error(file, 'write', value)
  fail_write_plane(rt, file, err)
  return nil, err
end

local function drain_writes_to(file, backend, target)
  local rt = Runtime.current()
  if not file._write_flow then return true end
  while file._written < target do
    local need = math.min(file._write_chunk_size, target - file._written)
    local lease, lease_err = IO.masked_perform(rt, file._write_flow:outlet():lease_some_op(need, file))
    if not lease then return nil, normalise_flow_error(file, 'write', lease_err) end
    local written, err = service_write(file, backend, lease)
    if not written then return nil, err end
  end
  return true
end

local function service_read(file, backend, item)
  local rt = Runtime.current()
  local space, generation = item.space, item.generation
  local bytes, err = backend:read(space:capacity())
  local current_generation = IO.masked_perform(rt, file._read_generation:read_op())
  if current_generation ~= generation then
    IO.masked_perform(rt, space:release_op())
    if type(bytes) == 'string' and #bytes > 0 then
      IO.masked_perform(rt, file._rewind:add_op(#bytes))
    end
    return true
  end
  local status, value = Transfer.settle_read(rt, space, bytes, err, { empty_is_eof = true })
  if status == 'eof' then
    IO.masked_perform(rt, file._eof:write_op(true))
    return true
  elseif status == 'error' then
    return nil, normalise_flow_error(file, 'read', value)
  elseif status == 'would_block' then
    local failure = IO.protocol_error('file', 'read', 'completion-driven file backend returned would-block', { path = file._path })
    IO.masked_perform(rt, file._read_flow:inlet():fail_op(failure))
    return nil, failure
  end
  return true
end

local function control_error(file, kind, err)
  return IOError.normalise(err, { domain = 'file', action = kind, path = file._path })
end

local function execute_control(file, provider, backend, message)
  local rt = Runtime.current()
  local command, target = message.command, message.target
  local kind, args = command.kind, command.args
  local drained, drain_err = drain_writes_to(file, backend, target)
  if not drained then return nil, drain_err, kind == 'close' end

  if kind == 'seek' then
    local rewound, rewind_err = rewind_backend(file, backend)
    if not rewound then return nil, rewind_err end
    return backend:seek(args.whence, args.offset)
  elseif kind == 'flush' then
    return backend:flush()
  elseif kind == 'sync' then
    if type(backend.sync) ~= 'function' then
      return nil, IOError.unsupported('file', 'sync', { path = file._path })
    end
    return backend:sync(args.data_only)
  elseif kind == 'rename' then
    local ok, err = provider:rename(file._path, args.path, file._provider_opts or {})
    if ok then
      file._path = args.path
      backend.path = args.path
      file._auto_unlink = false
    end
    return ok, err
  elseif kind == 'close' then
    local unlink_err
    if file._auto_unlink then
      local unlinked, err = provider:unlink(file._path, file._provider_opts or {})
      if unlinked or (IOError.is(err, 'system') and err.code == 'ENOENT') then
        file._auto_unlink = false
      else
        unlink_err = err
      end
    end
    local ok, err = backend:close(args.reason)
    if not ok then return nil, err, true end
    if unlink_err then return nil, unlink_err, true end
    return true, nil, true
  end
  return nil, IOError.invalid_argument('file', kind, { message = 'unknown file control command' })
end

local function read_candidate(file)
  if not file._read_flow or file._read_flow:_read_terminal_reason() then return nil end
  return file._eof:expect_op(false):and_then(file._read_generation:read_op()):and_then(Op.guard(function(generation)
    return file._read_flow:inlet():reserve_some_op(file._read_chunk_size, file, { generation = generation }):map(function(space)
      return { space = space, generation = generation }
    end)
  end))
end

local function next_driver_action(file)
  local control = file._control_rx:recv_op():map(function(message, err)
    if not message then return 'control_closed', err end
    return 'control', message
  end)
  local io
  if file._write_flow and not file._write_flow:_write_terminal_reason() then
    io = file._write_flow:outlet():lease_some_op(file._write_chunk_size, file):map(function(lease)
      return 'write', lease
    end)
  end
  local read = read_candidate(file)
  if read then
    read = read:map(function(item) return 'read', item end)
    io = io and io:or_else(read) or read
  end
  return io and control:or_else(io) or control
end

local function drive_file(file, opts)
  local rt = Runtime.current()
  local provider, provider_err = Provider.for_runtime(rt, opts)
  if not provider then
    publish(rt, file._ready_completion, false, provider_err)
    return nil, provider_err
  end

  local backend, open_err
  if file._temporary then
    local attempts = opts.attempts or 64
    for _ = 1, attempts do
      local candidate = temp_candidate(opts)
      local open_opts = { exclusive = true, permissions = opts.permissions or 384 }
      backend, open_err = provider:open(candidate, 'w+b', open_opts)
      if backend then
        file._path = candidate
        file._auto_unlink = true
        break
      end
      if not (IOError.is(open_err, 'system') and open_err.code == 'EEXIST') then break end
    end
  else
    backend, open_err = provider:open(file._path, file._mode, provider_open_options(opts))
  end

  if not backend then
    local failure = IOError.normalise(open_err, { domain = 'file', action = 'open', path = file._path })
    publish(rt, file._ready_completion, false, failure)
    if file._read_flow then IO.masked_perform(rt, file._read_flow:inlet():fail_op(failure)) end
    if file._write_flow then IO.masked_perform(rt, file._write_flow:outlet():fail_op(failure)) end
    return nil, failure
  end

  file._backend = backend
  publish(rt, file._ready_completion, true, true)

  while true do
    local action, item = IO.masked_perform(rt, next_driver_action(file))
    if action == 'control' then
      local called, ok, err, stop = Protected.pcall(execute_control, file, provider, backend, item)
      local command = item.command
      if not called then
        err = IO.protocol_error('file', command.kind, ok, { path = file._path })
        ok = nil
        stop = command.kind == 'close'
      end
      local failure = ok ~= nil and ok ~= false and nil or control_error(file, command.kind, err)
      if failure == nil then publish(rt, command.completion, true, ok) else
        publish(rt, command.completion, false, failure)
      end
      if stop then
        if not called then error(failure, 0) end
        return failure == nil and true or nil, failure
      end
    elseif action == 'write' then
      service_write(file, backend, item)
    elseif action == 'read' then
      service_read(file, backend, item)
    elseif action == 'control_closed' then
      local target = IO.masked_perform(rt, file._accepted:read_op())
      drain_writes_to(file, backend, target)
      local ok, err = backend:close('file control queue closed')
      return ok ~= nil and ok ~= false and true or nil, err
    end
  end
end

local function new_file_op(path, mode, opts, operation, temporary)
  opts = IO.copy_table(opts)
  local scope = IO.current_scope(opts, operation)
  local readable, writable = mode_capabilities(mode)
  next_file = next_file + 1
  local control_tx, control_rx = Mailbox.new(opts.queue_limit or 32)
  local read_capacity = validate_capacity(opts.read_capacity or opts.capacity, DEFAULT_READ_CAPACITY, 'file read_capacity')
  local write_capacity = opts.write_capacity or opts.capacity
  if write_capacity ~= nil then write_capacity = validate_capacity(write_capacity, nil, 'file write_capacity') end
  local read_flow = readable and Flow.new(read_capacity):label('file-' .. tostring(next_file) .. ':rx') or nil
  local write_flow = writable and Flow.new(write_capacity):label('file-' .. tostring(next_file) .. ':tx') or nil
  local file = Label.attach(setmetatable({
    kind = 'regular_file',
    _fibers_id = 'file-' .. tostring(next_file),
    _path = path,
    _mode = mode,
    _control_tx = control_tx,
    _control_rx = control_rx,
    _read_flow = read_flow,
    _write_flow = write_flow,
    _read_chunk_size = math.min(opts.read_chunk_size or opts.chunk_size or DEFAULT_CHUNK, read_capacity),
    _write_chunk_size = opts.write_chunk_size or opts.chunk_size or DEFAULT_CHUNK,
    _read_generation = Counter.new(0),
    _rewind = Counter.new(0),
    _accepted = Counter.new(0),
    _eof = Cell.new(false),
    _ready_completion = Completion.new(),
    _provider_opts = opts,
    _temporary = temporary == true,
    _written = 0,
  }, RegularFile), opts.label)

  Label.child(file._control_tx, file, 'control')
  Label.child(file._read_generation, file, 'read_generation')
  Label.child(file._rewind, file, 'rewind')
  Label.child(file._accepted, file, 'accepted')
  Label.child(file._eof, file, 'eof')
  Label.child(file._ready_completion, file, 'ready')

  local children = {}
  if read_flow then
    Label.child(read_flow, file, 'rx')
    children[#children + 1] = read_flow:inlet()
    children[#children + 1] = read_flow:outlet()
  end
  if write_flow then
    Label.child(write_flow, file, 'tx')
    children[#children + 1] = write_flow:inlet()
    children[#children + 1] = write_flow:outlet()
  end

  return scope:_drive_op( file, {
    label = Label.get(file),
    role = 'regular_file',
    closure = IO._closeable_closure(file, {
      name = 'regular_file',
      reason = 'file scope closure',
      finish_result = function(ok, err)
        if not ok and file._backend ~= nil then error(err or 'file closure failed', 0) end
        return true
      end,
    }),
    children = children,
    run = function()
      local ok, value, err = Protected.pcall(drive_file, file, opts)
      if ok then return value, err end
      local rt = Runtime.current()
      local failure = Runtime.is_cancelled(err)
          and file_closed_error(file, 'driver', err.reason or 'file driver cancelled')
        or IO.protocol_error('file', 'driver', err, { path = file._path })
      local cleanup_errors = {}
      if file._backend then
        IOError.capture_cleanup(cleanup_errors, 'file', 'driver_backend_close', nil, file._backend.close, file._backend, failure)
      end
      if file._auto_unlink then
        IOError.capture_cleanup(cleanup_errors, 'file', 'driver_auto_unlink', nil, function()
          local provider, provider_err = Provider.for_runtime(rt, opts)
          if not provider then return nil, provider_err end
          local unlinked, unlink_err = provider:unlink(file._path)
          if not unlinked and not (IOError.is(unlink_err, 'system') and unlink_err.code == 'ENOENT') then
            return nil, unlink_err
          end
          return true
        end)
      end
      failure = IOError.with_cleanup(failure, 'file', 'driver_cleanup',
        'file driver and cleanup both failed', cleanup_errors, { path = failure and failure.path or nil })
      if file._read_flow then IO.masked_perform(rt, file._read_flow:inlet():fail_op(failure)) end
      if file._write_flow then IO.masked_perform(rt, file._write_flow:outlet():fail_op(failure)) end
      if file._ready_completion:_is_pending() then publish(rt, file._ready_completion, false, failure) end
      if not Runtime.is_cancelled(err) then error(failure, 0) end
      return nil, failure
    end,
  })
end

local function ready_file(submission)
  return submission:wrap(function(file, err)
    if not file then return nil, err end
    local ready, ready_err = file:ready()
    if not ready then return nil, ready_err end
    return file
  end)
end

function File.submit_open_op(path, mode, opts)
  path, mode = validate_path(path, 'submit_open_op'), validate_mode(mode)
  return new_file_op(path, mode, opts, 'file.submit_open_op', false)
end
function File.open_op(path, mode, opts)
  path, mode = validate_path(path, 'open_op'), validate_mode(mode)
  return ready_file(new_file_op(path, mode, opts, 'file.open_op', false))
end
function File.submit_tmpfile_op(opts)
  return new_file_op('', 'w+b', opts, 'file.submit_tmpfile_op', true)
end
function File.tmpfile_op(opts)
  return ready_file(new_file_op('', 'w+b', opts, 'file.tmpfile_op', true))
end

function Job:result_op()
  return self._driver:await_op()
end

local function path_job_op(action, fn, opts)
  opts = IO.copy_table(opts)
  local operation = 'file.submit_' .. action .. '_op'
  local scope = IO.current_scope(opts, operation)
  next_job = next_job + 1
  local job = Label.attach(setmetatable({
    _fibers_id = 'file-' .. action .. '-' .. tostring(next_job),
  }, Job), opts.label)
  local submission = scope:_drive_op( job, {
    label = Label.get(job),
    role = 'file_job',
    closure = Closure.none(),
    run = function() return fn(opts) end,
  })
  return submission
end

local function job_result(submission)
  return submission:wrap(function(job, err)
    if not job then
      return nil, err
    end
    return job:result()
  end)
end

local function with_provider(opts, action, fn)
  local rt = current_runtime('file.' .. action)
  local provider, err = Provider.for_runtime(rt, opts)
  if not provider then
    return nil, err
  end
  return fn(provider)
end

local function child_file_opts(opts)
  local out = IO.copy_table(opts)
  out.scope = Runtime.current_scope()
  return out
end

local function read_all_job(path, opts, label)
  opts, path = IO.copy_table(opts), validate_path(path, label)
  local max, chunk = validate_read_limits(opts, 3)
  return path_job_op('read_all', function(job_opts)
    local opened, err = perform(File.open_op(path, 'rb', child_file_opts(job_opts)))
    if not opened then return nil, err end
    local value, read_err = opened:read_all({ max = max, chunk_size = chunk })
    local closed, close_err = opened:close('read complete')
    if value == nil then return nil, read_err end
    if not closed then return nil, close_err end
    return value
  end, opts)
end
function File.submit_read_all_op(path, opts)
  return read_all_job(path, opts, 'submit_read_all_op')
end
function File.read_all_op(path, opts)
  return job_result(read_all_job(path, opts, 'read_all_op'))
end

local function write_all_job(path, bytes, opts, label)
  opts, path = IO.copy_table(opts), validate_path(path, label)
  if type(bytes) ~= 'string' then error('file.' .. label .. ' expects bytes', 3) end
  local mode = validate_mode(opts.mode or (opts.append and 'ab' or 'wb'))
  return path_job_op('write_all', function(job_opts)
    local opened, err = perform(File.open_op(path, mode, child_file_opts(job_opts)))
    if not opened then return nil, err end
    local total, write_err = opened:write_all(bytes)
    if not total then
      opened:close('write failed')
      return nil, write_err
    end
    local flushed, flush_err = opened:flush()
    local closed, close_err = opened:close('write complete')
    if not flushed then return nil, flush_err end
    if not closed then return nil, close_err end
    return total
  end, opts)
end
function File.submit_write_all_op(path, bytes, opts)
  return write_all_job(path, bytes, opts, 'submit_write_all_op')
end
function File.write_all_op(path, bytes, opts)
  return job_result(write_all_job(path, bytes, opts, 'write_all_op'))
end

local function path_action(action, args, opts)
  return path_job_op(action, function(job_opts)
    return with_provider(job_opts, action, function(provider)
      if action == 'rename' then
        return provider:rename(args[1], args[2])
      end
      return provider[action](provider, args[1], provider_path_options(action, job_opts))
    end)
  end, opts)
end

local function path_action_result(action, args, opts)
  return job_result(path_action(action, args, opts))
end

function File.submit_rename_op(from, to, opts)
  from, to = validate_path(from, 'submit_rename_op'), validate_path(to, 'submit_rename_op')
  return (path_action('rename', { from, to }, opts))
end
function File.rename_op(from, to, opts)
  from, to = validate_path(from, 'rename_op'), validate_path(to, 'rename_op')
  return path_action_result('rename', { from, to }, opts)
end
local function unary_path_action(action, path, opts, submit)
  path = validate_path(path, (submit and 'submit_' or '') .. action .. '_op')
  local fn = submit and path_action or path_action_result
  return fn(action, { path }, opts)
end
function File.submit_unlink_op(path, opts) return unary_path_action('unlink', path, opts, true) end
function File.unlink_op(path, opts) return unary_path_action('unlink', path, opts, false) end
function File.submit_mkdir_op(path, opts) return unary_path_action('mkdir', path, opts, true) end
function File.mkdir_op(path, opts) return unary_path_action('mkdir', path, opts, false) end
local function mkdir_p_job(path, opts, label)
  path = validate_path(path, label)
  return path_job_op('mkdir_p', function(job_opts)
    return with_provider(job_opts, 'mkdir_p', function(provider)
      if type(provider.mkdir_p) == 'function' then
        return provider:mkdir_p(path, provider_path_options('mkdir_p', job_opts))
      end
      return nil, IOError.unsupported('file', 'mkdir_p', { path = path })
    end)
  end, opts)
end
function File.submit_mkdir_p_op(path, opts)
  return (mkdir_p_job(path, opts, 'submit_mkdir_p_op'))
end
function File.mkdir_p_op(path, opts)
  return job_result(mkdir_p_job(path, opts, 'mkdir_p_op'))
end


File.RegularFile = RegularFile
File.Command = Command
File.Job = Job
File.Error = IOError
Direct.install(Command, { 'result' })
Direct.install(RegularFile, { 'ready', 'read', 'read_some', 'write_some', 'read_line', 'seek', 'flush', 'rename', 'sync', 'close', 'closed' })
Direct.install(Job, { 'result' })
Direct.install_static(File, { 'open', 'tmpfile', 'read_all', 'write_all', 'rename', 'unlink', 'mkdir', 'mkdir_p' })

return File
