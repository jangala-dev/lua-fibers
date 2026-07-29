-- Runtime-only evented file and pipe facilities.
--
-- Regular-file calls are executed by an asynchronous provider. No public file
-- operation is available outside a running Fibers scope.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Completion = require('fibers.resource.completion')
local IO = require('fibers.io.facility')
local Mailbox = require('fibers.mailbox')
local Protected = require('fibers.protected')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')

local Algorithms = {}

function Algorithms.read_exactly(read, count, fields)
  local parts, total = {}, 0
  while total < count do
    local bytes, err = read(count - total)
    if bytes == nil then
      return nil, err
    end
    if bytes == '' then
      fields = fields or {}
      fields.expected = count
      fields.received = total
      return nil, IOError.eof('file', 'read_exactly', fields)
    end
    parts[#parts + 1] = bytes
    total = total + #bytes
  end
  return table.concat(parts)
end

function Algorithms.read_all(read, opts)
  opts = opts or {}
  local max = assert(opts.max)
  local chunk = assert(opts.chunk_size)
  local parts, total = {}, 0
  while total < max do
    local bytes, err = read(math.min(chunk, max - total))
    if bytes == nil then
      return nil, err
    end
    if bytes == '' then
      return table.concat(parts)
    end
    parts[#parts + 1] = bytes
    total = total + #bytes
  end

  local extra, err = read(1)
  if extra == nil then
    return nil, err
  end
  if extra ~= '' then
    if opts.restore_probe then
      local restored, restore_err = opts.restore_probe()
      if restored == nil or restored == false then
        return nil, restore_err
      end
    end
    return nil,
      IOError.system(
        'file',
        'read_all',
        'file exceeds configured maximum',
        'EFBIG',
        nil,
        { path = opts.path, max = max }
      )
  end
  return table.concat(parts)
end

function Algorithms.write_all(write, bytes, fields)
  local total = 0
  while total < #bytes do
    local written, err = write(bytes:sub(total + 1))
    if written == nil or written == false then
      return nil, err
    end
    if written <= 0 then
      return nil,
        IOError.system(
          'file',
          'write_all',
          'write made no progress',
          'EIO',
          nil,
          { path = fields and fields.path, written = total }
        )
    end
    total = total + written
  end
  return total
end

local Provider = {}
local by_runtime = setmetatable({}, { __mode = 'k' })

function Provider.for_runtime(runtime, opts)
  if not runtime then
    error('file provider requires a current runtime', 2)
  end
  local cached = by_runtime[runtime]
  if cached and (type(cached.is_supported) ~= 'function' or cached:is_supported()) then
    return cached
  end
  by_runtime[runtime] = nil

  local host = runtime.host
  if not host or type(host.file_provider) ~= 'function' then
    return nil, IOError.unsupported('file', 'provider', { host = host and host.name })
  end
  local ok, provider = pcall(host.file_provider, host, runtime, opts or {})
  if
    not ok
    or not provider
    or (type(provider.is_supported) == 'function' and not provider:is_supported())
  then
    return nil, IOError.unsupported('file', 'provider', { host = host.name })
  end

  by_runtime[runtime] = provider
  if type(provider.shutdown) == 'function' and type(runtime._add_finalizer) == 'function' then
    runtime:_add_finalizer(function()
      by_runtime[runtime] = nil
      return provider:shutdown()
    end)
  end
  return provider
end

local File = {}
local RegularFile = {}
RegularFile.__index = RegularFile
local Request = {}
Request.__index = Request
local Job = {}
Job.__index = Job
local next_file, next_request, next_job, next_temp = 0, 0, 0, 0

local DEFAULT_CHUNK = 16 * 1024
local DEFAULT_MAX = 16 * 1024 * 1024
local READ_LINE_EOF = {}

local function validate_path(path, action)
  if type(path) ~= 'string' or path == '' then
    error('file.' .. action .. ' expects a non-empty path string', 3)
  end
  return path
end

local function validate_mode(mode)
  mode = mode or 'r'
  local allowed = {
    r = true,
    rb = true,
    w = true,
    wb = true,
    a = true,
    ab = true,
    ['r+'] = true,
    ['r+b'] = true,
    ['rb+'] = true,
    ['w+'] = true,
    ['w+b'] = true,
    ['wb+'] = true,
    ['a+'] = true,
    ['a+b'] = true,
    ['ab+'] = true,
  }
  if not allowed[mode] then
    error('invalid regular-file mode ' .. tostring(mode), 3)
  end
  return mode
end

local function validate_read_limits(opts, level)
  opts = opts or {}
  local max = opts.max or DEFAULT_MAX
  local chunk = opts.chunk_size or DEFAULT_CHUNK
  level = (level or 1) + 1
  if type(max) ~= 'number' or max < 0 or max ~= math.floor(max) then
    error('file read max must be a non-negative integer', level)
  end
  if type(chunk) ~= 'number' or chunk < 1 or chunk ~= math.floor(chunk) then
    error('file read chunk_size must be a positive integer', level)
  end
  return max, chunk
end

local function validate_count(count, label, level)
  if type(count) ~= 'number' or count < 0 or count ~= math.floor(count) then
    error(label .. ' expects a non-negative integer', level or 3)
  end
  return count
end

local function join_path(directory, name)
  if directory:sub(-1) == '/' then
    return directory .. name
  end
  return directory .. '/' .. name
end

local function temp_candidate(opts)
  next_temp = next_temp + 1
  local directory = opts.directory or os.getenv('TMPDIR') or '/tmp'
  local prefix = opts.prefix or 'fibers-'
  local nonce = tostring(os.time())
    .. '-'
    .. tostring(next_temp)
    .. '-'
    .. tostring(math.random(0, 0x3fffffff))
  return join_path(directory, prefix .. nonce)
end

local function current_runtime(label)
  local rt = Runtime.current()
  if not rt or not Runtime.current_scope() then
    error(label .. ' requires a running Fibers scope', 3)
  end
  return rt
end

local function new_request(kind, args)
  next_request = next_request + 1
  local name = 'file-request-' .. tostring(next_request)
  return setmetatable(
    { kind = kind, args = args or {}, completion = Completion.new(name), name = name },
    Request
  )
end
function Request:result_op()
  return self.completion:result_op()
end
function Request:result()
  return perform(self:result_op())
end

local function file_closure(file)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return file:close_op(reason or 'file scope closure')
  end, function()
    return file:closed_op()
  end, {
    name = 'regular_file',
    finish_result = function(ok, err)
      -- A failed open owns no host file; its terminal error is the acquisition
      -- result, not a second closure failure.
      if not ok and file.backend ~= nil then
        error(err or 'file closure failed', 0)
      end
      return true
    end,
  })
end

function RegularFile:ready_op()
  return self.ready_completion:result_op()
end
function RegularFile:is_file()
  return true
end
function RegularFile:filename()
  return self.path
end
function RegularFile:closed_op()
  -- Host closure may be published before the private driver Scope has retired
  -- every child. A successful File close therefore joins both conditions.
  return IO.closed_after_driver_op(self.driver, self.closed_completion:result_op(), {
    require_returned = true,
  })
end

local function enqueue(file, kind, args)
  if not file.closed_completion:is_pending() then
    return Op.always(nil, IOError.closed('file', kind, { path = file.path }))
  end
  local request = new_request(kind, args)
  return file.tx:send_op(request):map(function()
    return request
  end), request
end

local function request_result(file, kind, args)
  local submission = enqueue(file, kind, args)
  return submission:wrap(function(request, err)
    if not request then
      return nil, err
    end
    return request:result()
  end)
end

function RegularFile:submit_read_op(count)
  return (enqueue(self, 'read', { count = validate_count(count, 'File:submit_read_op', 2) }))
end
function RegularFile:read_op(count)
  return request_result(self, 'read', { count = validate_count(count, 'File:read_op', 2) })
end

function RegularFile:submit_read_exactly_op(count)
  return (enqueue(self, 'read_exactly', { count = validate_count(count, 'File:submit_read_exactly_op', 2) }))
end
function RegularFile:read_exactly_op(count)
  return request_result(self, 'read_exactly', { count = validate_count(count, 'File:read_exactly_op', 2) })
end

function RegularFile:submit_write_op(bytes)
  if type(bytes) ~= 'string' then
    error('File:submit_write_op expects a string', 2)
  end
  return (enqueue(self, 'write', { bytes = bytes }))
end
function RegularFile:write_op(bytes)
  if type(bytes) ~= 'string' then
    error('File:write_op expects a string', 2)
  end
  return request_result(self, 'write', { bytes = bytes })
end

function RegularFile:submit_read_line_op(keep)
  return (enqueue(self, 'read_line', { keep = keep == true }))
end
function RegularFile:read_line_op(keep)
  return request_result(self, 'read_line', { keep = keep == true })
end

function RegularFile:submit_rename_op(path)
  path = validate_path(path, 'submit_rename_op')
  return (enqueue(self, 'rename', { path = path }))
end
function RegularFile:rename_op(path)
  path = validate_path(path, 'rename_op')
  return request_result(self, 'rename', { path = path })
end

local function seek_args(whence, offset, label)
  whence, offset = whence or 'cur', offset or 0
  if whence ~= 'set' and whence ~= 'cur' and whence ~= 'end' then
    error("seek whence must be 'set', 'cur' or 'end'", 3)
  end
  if type(offset) ~= 'number' or offset ~= math.floor(offset) then
    error('seek offset must be an integer', 3)
  end
  return { whence = whence, offset = offset, label = label }
end
function RegularFile:submit_seek_op(whence, offset)
  local args = seek_args(whence, offset, 'submit_seek_op')
  return (enqueue(self, 'seek', args))
end
function RegularFile:seek_op(whence, offset)
  return request_result(self, 'seek', seek_args(whence, offset, 'seek_op'))
end

function RegularFile:submit_flush_op()
  return (enqueue(self, 'flush'))
end
function RegularFile:flush_op()
  return request_result(self, 'flush')
end
function RegularFile:submit_sync_op(opts)
  return (enqueue(self, 'sync', { data_only = opts and opts.data_only == true }))
end
function RegularFile:sync_op(opts)
  return request_result(self, 'sync', { data_only = opts and opts.data_only == true })
end

function RegularFile:close_op(reason)
  if not self.closed_completion:is_pending() then
    return self:closed_op()
  end
  local request = new_request('close', { reason = reason })
  return self.tx:send_op(request):and_then(self.tx:close_op(reason or 'file close requested')):wrap(function()
    return self:closed()
  end)
end

function RegularFile:submit_read_all_op(opts)
  local max, chunk = validate_read_limits(opts, 2)
  return (enqueue(self, 'read_all', { max = max, chunk_size = chunk }))
end
function RegularFile:read_all_op(opts)
  local max, chunk = validate_read_limits(opts, 2)
  return request_result(self, 'read_all', { max = max, chunk_size = chunk })
end
function RegularFile:submit_write_all_op(bytes)
  if type(bytes) ~= 'string' then
    error('File:submit_write_all_op expects a string', 2)
  end
  return (enqueue(self, 'write_all', { bytes = bytes }))
end
function RegularFile:write_all_op(bytes)
  if type(bytes) ~= 'string' then
    error('File:write_all_op expects a string', 2)
  end
  return request_result(self, 'write_all', { bytes = bytes })
end

local function write_parts(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if type(value) ~= 'string' and type(value) ~= 'number' then
      error('File:write expects strings or numbers', 3)
    end
    parts[i] = tostring(value)
  end
  return table.concat(parts)
end

function RegularFile:ready()
  return perform(self:ready_op())
end
function RegularFile:read(count)
  return perform(self:read_op(count))
end
function RegularFile:read_exactly(count)
  return perform(self:read_exactly_op(count))
end
function RegularFile:write(...)
  return perform(self:write_op(write_parts(...)))
end
function RegularFile:write_all(bytes)
  return perform(self:write_all_op(bytes))
end
function RegularFile:seek(whence, offset)
  return perform(self:seek_op(whence, offset))
end
function RegularFile:read_line(keep)
  return perform(self:read_line_op(keep))
end
function RegularFile:read_all(opts)
  return perform(self:read_all_op(opts))
end
function RegularFile:rename(path)
  return perform(self:rename_op(path))
end
function RegularFile:flush()
  return perform(self:flush_op())
end
function RegularFile:sync(opts)
  return perform(self:sync_op(opts))
end
function RegularFile:close(reason)
  return perform(self:close_op(reason))
end
function RegularFile:closed()
  return perform(self:closed_op())
end

local function publish(rt, completion, ok, ...)
  if ok then
    return IO.masked_perform(rt, completion:publish_success_op(...))
  end
  return IO.masked_perform(rt, completion:publish_failure_op((...)))
end

local function execute_request(file, provider, backend, request)
  local kind, args = request.kind, request.args
  if kind == 'read' then
    return backend:read(args.count)
  elseif kind == 'read_exactly' then
    return Algorithms.read_exactly(function(count)
      return backend:read(count)
    end, args.count, { path = file.path })
  elseif kind == 'read_all' then
    return Algorithms.read_all(function(count)
      return backend:read(count)
    end, {
      max = args.max,
      chunk_size = args.chunk_size,
      path = file.path,
      restore_probe = function()
        return backend:seek('cur', -1)
      end,
    })
  elseif kind == 'read_line' then
    local value, err = backend:read_line(args.keep)
    if value == nil and err == nil then
      return READ_LINE_EOF
    end
    return value, err
  elseif kind == 'write' then
    return backend:write(args.bytes)
  elseif kind == 'write_all' then
    return Algorithms.write_all(function(part)
      return backend:write(part)
    end, args.bytes, { path = file.path })
  elseif kind == 'seek' then
    return backend:seek(args.whence, args.offset)
  elseif kind == 'flush' then
    return backend:flush()
  elseif kind == 'sync' then
    if type(backend.sync) ~= 'function' then
      return nil, IOError.unsupported('file', 'sync', { path = file.path })
    end
    return backend:sync(args.data_only)
  elseif kind == 'rename' then
    local ok, err = provider:rename(file.path, args.path, file.provider_opts or {})
    if ok then
      file.path = args.path
      backend.path = args.path
      file.auto_unlink = false
    end
    return ok, err
  elseif kind == 'close' then
    local unlink_err
    if file.auto_unlink then
      -- Unlink while the descriptor is still open. Besides matching POSIX
      -- temporary-file semantics, this keeps completion-backed providers such
      -- as io_uring alive until the final path operation has completed.
      local unlinked, err = provider:unlink(file.path, file.provider_opts or {})
      if unlinked or (IOError.is(err, 'system') and err.code == 'ENOENT') then
        file.auto_unlink = false
      else
        unlink_err = err
      end
    end
    local ok, err = backend:close(args.reason)
    if not ok then
      return nil, err
    end
    if unlink_err then
      return nil, unlink_err
    end
    return true
  end
  return nil, IOError.invalid_argument('file', kind, { message = 'unknown file request' })
end

local function drive_file(file, opts)
  local rt = Runtime.current()
  local provider, provider_err = Provider.for_runtime(rt, opts)
  if not provider then
    publish(rt, file.ready_completion, false, provider_err)
    IO.masked_perform(rt, file.tx:close_op(provider_err))
    publish(rt, file.closed_completion, false, provider_err)
    return
  end
  local backend, open_err
  if file.temporary then
    local attempts = opts.attempts or 64
    for _ = 1, attempts do
      local candidate = temp_candidate(opts)
      local open_opts = IO.copy_table(opts)
      open_opts.exclusive = true
      open_opts.permissions = opts.permissions or 384
      backend, open_err = provider:open(candidate, 'w+b', open_opts)
      if backend then
        file.path = candidate
        file.auto_unlink = true
        break
      end
      if not (IOError.is(open_err, 'system') and open_err.code == 'EEXIST') then
        break
      end
    end
  else
    backend, open_err = provider:open(file.path, file.mode, opts)
  end
  if not backend then
    local failure = IOError.normalise(open_err, { domain = 'file', action = 'open', path = file.path })
    publish(rt, file.ready_completion, false, failure)
    IO.masked_perform(rt, file.tx:close_op(failure))
    publish(rt, file.closed_completion, false, failure)
    return
  end
  file.backend = backend
  publish(rt, file.ready_completion, true, true)
  while true do
    local request = file.rx:recv()
    if not request then
      break
    end
    local ok, value, err = Protected.pcall(execute_request, file, provider, backend, request)
    if not ok then
      publish(
        rt,
        request.completion,
        false,
        IO.protocol_error('file', request.kind, value, { path = file.path })
      )
    elseif value == READ_LINE_EOF then
      publish(rt, request.completion, true, nil)
    elseif value == nil or value == false then
      publish(
        rt,
        request.completion,
        false,
        IOError.normalise(err, { domain = 'file', action = request.kind, path = file.path })
      )
    else
      publish(rt, request.completion, true, value, err)
    end
    if request.kind == 'close' then
      publish(
        rt,
        file.closed_completion,
        value ~= nil and value ~= false,
        value ~= nil and value ~= false and true or err
      )
      return
    end
  end
  local ok, err = backend:close('file request queue closed')
  if ok and file.auto_unlink then
    local unlinked, unlink_err = provider:unlink(file.path, file.provider_opts or {})
    if not unlinked and not (IOError.is(unlink_err, 'system') and unlink_err.code == 'ENOENT') then
      ok, err = nil, unlink_err
    end
    file.auto_unlink = false
  end
  publish(rt, file.closed_completion, ok ~= nil and ok ~= false, ok ~= nil and ok ~= false and true or err)
end

local function new_file_op(path, mode, opts, label, temporary)
  opts = IO.copy_table(opts)
  local scope = IO.current_scope(opts, label)
  next_file = next_file + 1
  local name = opts.name or ('file-' .. tostring(next_file))
  local tx, rx = Mailbox.new(opts.queue_limit or 32, name .. ':requests')
  local file = setmetatable({
    kind = 'regular_file',
    name = name,
    path = path,
    mode = mode,
    tx = tx,
    rx = rx,
    ready_completion = Completion.new(name .. ':ready'),
    closed_completion = Completion.new(name .. ':closed'),
    backend = nil,
    driver = nil,
    provider_opts = opts,
    temporary = temporary == true,
    auto_unlink = false,
  }, RegularFile)
  local admission = IO.admit_driven_lifetime_op(scope, file, {
    label = label,
    name = name,
    role = 'regular_file',
    closure = file_closure(file),
    run = function()
      local ok, err = Protected.pcall(drive_file, file, opts)
      if ok then
        return
      end
      local rt = Runtime.current()
      local failure = Runtime.is_cancelled(err)
          and IOError.closed(
            'file',
            'driver',
            { path = file.path, reason = err.reason or 'file driver cancelled' }
          )
        or IO.protocol_error('file', 'driver', err, { path = file.path })
      if file.backend then
        Protected.pcall(file.backend.close, file.backend, failure)
      end
      if file.auto_unlink then
        Protected.pcall(function()
          local provider = Provider.for_runtime(rt, opts)
          if provider then
            provider:unlink(file.path, opts)
          end
        end)
      end
      if file.ready_completion:is_pending() then
        publish(rt, file.ready_completion, false, failure)
      end
      IO.masked_perform(rt, file.tx:close_op(failure))
      if file.closed_completion:is_pending() then
        publish(rt, file.closed_completion, false, failure)
      end
      if not Runtime.is_cancelled(err) then
        error(failure, 0)
      end
    end,
  })
  return admission, file
end

function File.submit_open_op(path, mode, opts)
  path, mode = validate_path(path, 'submit_open_op'), validate_mode(mode)
  return (new_file_op(path, mode, opts, 'file.submit_open_op', false))
end
function File.open_op(path, mode, opts)
  path, mode = validate_path(path, 'open_op'), validate_mode(mode)
  local submission = new_file_op(path, mode, opts, 'file.open_op', false)
  return submission:wrap(function(file, err)
    if not file then
      return nil, err
    end
    local ready, ready_err = file:ready()
    if not ready then
      return nil, ready_err
    end
    return file
  end)
end
function File.submit_tmpfile_op(opts)
  return (new_file_op('', 'w+b', opts, 'file.submit_tmpfile_op', true))
end
function File.tmpfile_op(opts)
  local submission = new_file_op('', 'w+b', opts, 'file.tmpfile_op', true)
  return submission:wrap(function(file, err)
    if not file then
      return nil, err
    end
    local ready, ready_err = file:ready()
    if not ready then
      return nil, ready_err
    end
    return file
  end)
end
function File.open(path, mode, opts)
  return perform(File.open_op(path, mode, opts))
end
function File.tmpfile(opts)
  return perform(File.tmpfile_op(opts))
end

function Job:result_op()
  return self.driver:await_op()
end
function Job:result()
  return perform(self:result_op())
end

local function path_job_op(action, fn, opts)
  opts = IO.copy_table(opts)
  local scope = IO.current_scope(opts, 'file.submit_' .. action .. '_op')
  next_job = next_job + 1
  local name = opts.name or ('file-' .. action .. '-' .. tostring(next_job))
  local job = setmetatable({ name = name }, Job)
  local submission = IO.admit_driven_lifetime_op(scope, job, {
    label = 'file.submit_' .. action .. '_op',
    name = name,
    role = 'file_job',
    closure = Closure.none(),
    run = function()
      return fn(opts)
    end,
  })
  return submission, job
end

local function job_result(submission, _job)
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

local function read_all_job(path, opts, label)
  opts, path = IO.copy_table(opts), validate_path(path, label)
  local max, chunk = validate_read_limits(opts, 3)
  return path_job_op('read_all', function(job_opts)
    local file, err = with_provider(job_opts, 'read_all', function(provider)
      return provider:open(path, 'rb', job_opts)
    end)
    if not file then
      return nil, err
    end
    local value, read_err = Algorithms.read_all(function(count)
      return file:read(count)
    end, {
      max = max,
      chunk_size = chunk,
      path = path,
    })
    local closed, close_err = file:close('read complete')
    if value == nil then
      return nil, read_err
    end
    if not closed then
      return nil, close_err
    end
    return value
  end, opts)
end
function File.submit_read_all_op(path, opts)
  return (read_all_job(path, opts, 'submit_read_all_op'))
end
function File.read_all_op(path, opts)
  local submission, job = read_all_job(path, opts, 'read_all_op')
  return job_result(submission, job)
end

local function write_all_job(path, bytes, opts, label)
  opts, path = IO.copy_table(opts), validate_path(path, label)
  if type(bytes) ~= 'string' then
    error('file.' .. label .. ' expects bytes', 3)
  end
  local mode = validate_mode(opts.mode or (opts.append and 'ab' or 'wb'))
  return path_job_op('write_all', function(job_opts)
    local file, err = with_provider(job_opts, 'write_all', function(provider)
      return provider:open(path, mode, job_opts)
    end)
    if not file then
      return nil, err
    end
    local total, write_err = Algorithms.write_all(function(part)
      return file:write(part)
    end, bytes, { path = path })
    if not total then
      file:close('write failed')
      return nil, write_err
    end
    local flushed, flush_err = file:flush()
    local closed, close_err = file:close('write complete')
    if not flushed then
      return nil, flush_err
    end
    if not closed then
      return nil, close_err
    end
    return total
  end, opts)
end
function File.submit_write_all_op(path, bytes, opts)
  return (write_all_job(path, bytes, opts, 'submit_write_all_op'))
end
function File.write_all_op(path, bytes, opts)
  local submission, job = write_all_job(path, bytes, opts, 'write_all_op')
  return job_result(submission, job)
end

local function path_action(action, args, opts)
  return path_job_op(action, function(job_opts)
    return with_provider(job_opts, action, function(provider)
      if action == 'rename' then
        return provider:rename(args[1], args[2], job_opts)
      end
      return provider[action](provider, args[1], job_opts)
    end)
  end, opts)
end

local function path_action_result(action, args, opts)
  local submission, job = path_action(action, args, opts)
  return job_result(submission, job)
end

function File.submit_rename_op(from, to, opts)
  from, to = validate_path(from, 'submit_rename_op'), validate_path(to, 'submit_rename_op')
  return (path_action('rename', { from, to }, opts))
end
function File.rename_op(from, to, opts)
  from, to = validate_path(from, 'rename_op'), validate_path(to, 'rename_op')
  return path_action_result('rename', { from, to }, opts)
end
function File.submit_unlink_op(path, opts)
  path = validate_path(path, 'submit_unlink_op')
  return (path_action('unlink', { path }, opts))
end
function File.unlink_op(path, opts)
  path = validate_path(path, 'unlink_op')
  return path_action_result('unlink', { path }, opts)
end
function File.submit_mkdir_op(path, opts)
  path = validate_path(path, 'submit_mkdir_op')
  return (path_action('mkdir', { path }, opts))
end
function File.mkdir_op(path, opts)
  path = validate_path(path, 'mkdir_op')
  return path_action_result('mkdir', { path }, opts)
end
local function mkdir_p_job(path, opts, label)
  path = validate_path(path, label)
  return path_job_op('mkdir_p', function(job_opts)
    return with_provider(job_opts, 'mkdir_p', function(provider)
      if type(provider.mkdir_p) == 'function' then
        return provider:mkdir_p(path, job_opts)
      end
      return nil, IOError.unsupported('file', 'mkdir_p', { path = path })
    end)
  end, opts)
end
function File.submit_mkdir_p_op(path, opts)
  return (mkdir_p_job(path, opts, 'submit_mkdir_p_op'))
end
function File.mkdir_p_op(path, opts)
  local submission, job = mkdir_p_job(path, opts, 'mkdir_p_op')
  return job_result(submission, job)
end

function File.read_all(path, opts)
  return perform(File.read_all_op(path, opts))
end
function File.write_all(path, bytes, opts)
  return perform(File.write_all_op(path, bytes, opts))
end
function File.rename(from, to, opts)
  return perform(File.rename_op(from, to, opts))
end
function File.unlink(path, opts)
  return perform(File.unlink_op(path, opts))
end
function File.mkdir(path, opts)
  return perform(File.mkdir_op(path, opts))
end
function File.mkdir_p(path, opts)
  return perform(File.mkdir_p_op(path, opts))
end

File.RegularFile = RegularFile
File.Request = Request
File.Job = Job
File.Error = IOError
return File
