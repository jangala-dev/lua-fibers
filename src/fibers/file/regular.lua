-- Runtime-only evented file and pipe facilities.
--
-- Regular-file calls are executed by an asynchronous provider. No public file
-- operation is available outside a running Fibers scope.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Completion = require('fibers.resource.completion')
local Flow = require('fibers.resource.flow')
local FlowErrors = require('fibers.resource.flow.errors')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Transfer = require('fibers.io.internal.flow_transfer')
local ByteProtocol = require('fibers.internal.byte_protocol')
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

local DEFAULT_CHUNK = 16 * 1024
local DEFAULT_READ_CAPACITY = 64 * 1024
local DEFAULT_MAX = 16 * 1024 * 1024
local FILE_MODES = {
  r = true, rb = true, w = true, wb = true, a = true, ab = true,
  ['r+'] = true, ['r+b'] = true, ['rb+'] = true,
  ['w+'] = true, ['w+b'] = true, ['wb+'] = true,
  ['a+'] = true, ['a+b'] = true, ['ab+'] = true,
}

local function validate_path(path, action)
  if type(path) ~= 'string' or path == '' then
    error('file.' .. action .. ' expects a non-empty path string', 3)
  end
  return path
end

local function validate_mode(mode)
  mode = mode or 'r'
  if not FILE_MODES[mode] then
    error('invalid regular-file mode ' .. tostring(mode), 3)
  end
  return mode
end

local function mode_capabilities(mode)
  local first = mode:sub(1, 1)
  return first == 'r' or mode:find('+', 1, true) ~= nil,
    first == 'w' or first == 'a' or mode:find('+', 1, true) ~= nil
end

local function validate_read_limits(opts, level)
  local max = opts and opts.max or DEFAULT_MAX
  local chunk = opts and opts.chunk_size or DEFAULT_CHUNK
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

local function file_closed_error(file, action, reason)
  return IOError.closed('file', action, { path = file._path, reason = reason })
end

local function require_direction(file, side, action)
  if side == 'read' and not file._read_flow then
    return nil, IOError.invalid_argument('file', action, { path = file._path, message = 'file is not readable' })
  end
  if side == 'write' and not file._write_flow then
    return nil, IOError.invalid_argument('file', action, { path = file._path, message = 'file is not writable' })
  end
  return true
end

local function normalise_flow_error(file, action, err)
  if err == nil then return nil end
  if IOError.is(err) then return err end
  if err == FlowErrors.CLOSED or err == FlowErrors.BROKEN_PIPE or err == FlowErrors.RETIRED or err == FlowErrors.EOF then
    return file_closed_error(file, action, err)
  end
  if err == FlowErrors.CAPACITY then
    return IOError.invalid_argument('file', action, { path = file._path, message = 'operation exceeds configured buffer capacity' })
  end
  if err == FlowErrors.LINE_TOO_LONG or err == FlowErrors.TOO_LARGE then
    return IOError.system('file', action, 'buffered read exceeds configured limit', 'EFBIG', nil, { path = file._path })
  end
  return IOError.normalise(err, { domain = 'file', action = action, path = file._path })
end

local function file_closure(file)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return file:close_op(reason or 'file scope closure')
  end, function()
    return file:closed_op()
  end, {
    name = 'regular_file',
    finish_result = function(ok, err)
      if not ok and file._backend ~= nil then error(err or 'file closure failed', 0) end
      return true
    end,
  })
end

function RegularFile:ready_op()
  return self._ready_completion:result_op()
end
function RegularFile:is_file() return true end
function RegularFile:filename() return self._path end
function RegularFile:closed_op()
  return IO.closed_after_driver_op(self._driver, self._closed_completion:result_op(), { require_returned = true })
end

local function eof_fallback(file, op)
  return op:or_else(file._eof:expect_op(true):map(function() return nil, FlowErrors.EOF end))
end

function RegularFile:read_op(count)
  count = validate_count(count, 'File:read_op', 2)
  if count == 0 then return Op.always('') end
  local ok, err = require_direction(self, 'read', 'read')
  if not ok then return Op.always(nil, err) end
  if not self._closed_completion:_is_pending() then return Op.always(nil, file_closed_error(self, 'read')) end
  return eof_fallback(self, self._read_flow:outlet():read_some_op(count)):map(function(bytes, read_err)
    if bytes ~= nil then return bytes end
    if read_err == FlowErrors.EOF then return '' end
    return nil, normalise_flow_error(self, 'read', read_err)
  end)
end

function RegularFile:read_some_op(count)
  return self:read_op(count)
end

local function read_some_protocol(file, count)
  local value, err = perform(file:read_op(count))
  if value == '' then return nil, FlowErrors.EOF end
  return value, err
end

function RegularFile:read_exactly_op(count)
  count = validate_count(count, 'File:read_exactly_op', 2)
  if count == 0 then return Op.always('') end
  local ok, err = require_direction(self, 'read', 'read_exactly')
  if not ok then return Op.always(nil, err) end
  if not self._closed_completion:_is_pending() then
    return Op.always(nil, file_closed_error(self, 'read_exactly'))
  end
  local capacity = self._read_flow._capacity
  if capacity ~= math.huge and count > capacity then
    return Op.always(nil, normalise_flow_error(self, 'read_exactly', FlowErrors.CAPACITY))
  end

  return self._eof:read_op():and_then(Op.guard(function(at_eof)
    local read = at_eof and self._read_flow:outlet():_take_available_op(count)
      or self._read_flow:outlet():read_exactly_op(count)
    return read:map(function(value, read_err)
      if value ~= nil and #value == count then return value end
      if read_err ~= nil then
        return nil, normalise_flow_error(self, 'read_exactly', read_err)
      end
      local partial = value or ''
      return nil, IOError.eof('file', 'read_exactly', {
        path = self._path,
        expected = count,
        received = #partial,
      })
    end)
  end))
end

function RegularFile:read_exactly(count)
  count = validate_count(count, 'File:read_exactly', 2)
  if count == 0 then return '' end
  local value, err, partial = ByteProtocol.read_exactly(
    function(want) return read_some_protocol(self, want) end,
    count,
    FlowErrors.EOF
  )
  if value ~= nil then return value end
  if err ~= FlowErrors.EOF then return nil, err end
  return nil, IOError.eof('file', 'read_exactly', {
    path = self._path,
    expected = count,
    received = #(partial or ''),
  })
end

function RegularFile:read_line_op(keep)
  local ok, err = require_direction(self, 'read', 'read_line')
  if not ok then return Op.always(nil, err) end
  if not self._closed_completion:_is_pending() then return Op.always(nil, file_closed_error(self, 'read_line')) end
  local capacity = self._read_flow._capacity
  local line = self._read_flow:outlet():read_line_op({
    keep_terminator = keep == true,
    max = capacity == math.huge and DEFAULT_MAX or math.max(0, capacity - 1),
  })
  local preferred = line:map(function(value, read_err) return 'line', value, read_err end)
  local at_eof = self._eof:expect_op(true)
    :and_then(self._read_flow:outlet():read_some_op(capacity):or_else(Op.always('')))
    :map(function(value, read_err) return 'eof', value, read_err end)
  return preferred:or_else(at_eof):map(function(source, value, read_err)
    if source == 'eof' then return value ~= '' and value or nil end
    if value ~= nil then return value end
    if read_err == nil or read_err == FlowErrors.EOF then return nil end
    return nil, normalise_flow_error(self, 'read_line', read_err)
  end)
end

local function peek_more_or_eof_op(file)
  local buffered = file._read_flow:outlet():peek_exactly_op(1):map(function(byte, err)
    return 'buffered', byte, err
  end)
  local at_eof = file._eof:expect_op(true):map(function() return 'eof' end)
  return buffered:or_else(at_eof)
end

function RegularFile:read_all_op(opts)
  local max = validate_read_limits(opts, 2)
  local ok, err = require_direction(self, 'read', 'read_all')
  if not ok then return Op.always(nil, err) end
  if not self._closed_completion:_is_pending() then
    return Op.always(nil, file_closed_error(self, 'read_all'))
  end

  return self._eof:read_op():and_then(Op.guard(function(at_eof)
    local read = at_eof and self._read_flow:outlet():_take_all_available_op(max)
      or self._read_flow:outlet():read_all_op({ max = max })
    return read:map(function(value, read_err)
      if value ~= nil then return value end
      return nil, normalise_flow_error(self, 'read_all', read_err)
    end)
  end))
end

function RegularFile:read_all(opts)
  local max, chunk = validate_read_limits(opts, 2)
  local value, err = ByteProtocol.read_all(
    function(want) return read_some_protocol(self, want) end,
    function()
      local source, byte, read_err = perform(peek_more_or_eof_op(self))
      if source == 'eof' then return nil, FlowErrors.EOF end
      return byte, read_err
    end,
    max,
    chunk,
    FlowErrors.EOF,
    FlowErrors.TOO_LARGE
  )
  if value ~= nil then return value end
  if err == FlowErrors.TOO_LARGE then
    return nil, IOError.system('file', 'read_all', 'file exceeds configured maximum', 'EFBIG', nil, {
      path = self._path,
      max = max,
    })
  end
  return nil, normalise_flow_error(self, 'read_all', err)
end

local function invalidate_read_op(file)
  if not file._read_flow then return Op.always(0) end
  return file._read_flow:outlet():_discard_available_op():and_then(Op.guard(function(discarded)
    return file._read_generation:bump_op()
      :and_then(file._rewind:add_op(discarded))
      :and_then(file._eof:write_op(false))
      :map(function() return discarded end)
  end))
end

function RegularFile:write_op(bytes)
  if type(bytes) ~= 'string' then error('File:write_op expects a string', 2) end
  if bytes == '' then return Op.always(0) end
  local ok, err = require_direction(self, 'write', 'write')
  if not ok then return Op.always(nil, err) end
  if not self._closed_completion:_is_pending() then return Op.always(nil, file_closed_error(self, 'write')) end
  local capacity = self._write_flow._capacity
  if capacity ~= math.huge and #bytes > capacity then
    return Op.always(nil, normalise_flow_error(self, 'write', FlowErrors.CAPACITY))
  end
  return self._write_flow:inlet():write_op(bytes):and_then(Op.guard(function(n, write_err)
    if n == nil then return Op.always(nil, normalise_flow_error(self, 'write', write_err)) end
    return invalidate_read_op(self)
      :and_then(self._accepted:add_op(n))
      :map(function() return n end)
  end))
end

function RegularFile:write_some_op(bytes)
  if type(bytes) ~= 'string' then error('File:write_some_op expects a string', 2) end
  if bytes == '' then return Op.always(0, '') end
  local ok, err = require_direction(self, 'write', 'write_some')
  if not ok then return Op.always(nil, bytes, err) end
  if not self._closed_completion:_is_pending() then
    return Op.always(nil, bytes, file_closed_error(self, 'write_some'))
  end
  return self._write_flow:inlet():write_some_op(bytes):and_then(Op.guard(function(n, rest, write_err)
    if n == nil then
      return Op.always(nil, rest, normalise_flow_error(self, 'write_some', write_err))
    end
    if n == 0 then return Op.always(0, rest) end
    return invalidate_read_op(self)
      :and_then(self._accepted:add_op(n))
      :map(function() return n, rest end)
  end))
end

function RegularFile:write_all_op(bytes)
  return self:write_op(bytes)
end

function RegularFile:write_all(bytes)
  if type(bytes) ~= 'string' then error('File:write_all expects a string', 2) end
  if bytes == '' then return 0 end
  local capacity = self._write_flow and self._write_flow._capacity or 0
  if capacity == 0 then
    local ok, err = require_direction(self, 'write', 'write_all')
    if not ok then return nil, err end
    return nil, normalise_flow_error(self, 'write_all', FlowErrors.CAPACITY)
  end
  local chunk = capacity == math.huge and #bytes or capacity
  return ByteProtocol.write_all(function(part) return perform(self:write_op(part)) end, bytes, chunk)
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

function RegularFile:write(...)
  return perform(self:write_op(write_parts(...)))
end

local function control_submission(file, kind, args, invalidate)
  if not file._closed_completion:_is_pending() then
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
  if not self._closed_completion:_is_pending() then return self:closed_op() end
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
  file._write_terminal = true
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
    file._read_terminal = true
    return nil, normalise_flow_error(file, 'read', value)
  elseif status == 'would_block' then
    local failure = IO.protocol_error('file', 'read', 'completion-driven file backend returned would-block', { path = file._path })
    file._read_terminal = true
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
  if not file._read_flow or file._read_terminal then return nil end
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
  if file._write_flow and not file._write_terminal then
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
    publish(rt, file._closed_completion, false, provider_err)
    return
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
    publish(rt, file._closed_completion, false, failure)
    return
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
        publish(rt, file._closed_completion, failure == nil, failure == nil and true or failure)
        if not called then error(failure, 0) end
        return
      end
    elseif action == 'write' then
      service_write(file, backend, item)
    elseif action == 'read' then
      service_read(file, backend, item)
    elseif action == 'control_closed' then
      local target = IO.masked_perform(rt, file._accepted:read_op())
      drain_writes_to(file, backend, target)
      local ok, err = backend:close('file control queue closed')
      publish(rt, file._closed_completion, ok ~= nil and ok ~= false, ok ~= nil and ok ~= false and true or err)
      return
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
    _closed_completion = Completion.new(),
    _provider_opts = opts,
    _temporary = temporary == true,
    _written = 0,
    _read_terminal = false,
    _write_terminal = false,
  }, RegularFile), opts.label)

  Label.child(file._control_tx, file, 'control')
  Label.child(file._read_generation, file, 'read_generation')
  Label.child(file._rewind, file, 'rewind')
  Label.child(file._accepted, file, 'accepted')
  Label.child(file._eof, file, 'eof')
  Label.child(file._ready_completion, file, 'ready')
  Label.child(file._closed_completion, file, 'closed')

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

  return IO.admit_driven_lifetime_op(scope, file, {
    operation = operation,
    label = Label.get(file),
    role = 'regular_file',
    closure = file_closure(file),
    children = children,
    run = function()
      local ok, err = Protected.pcall(drive_file, file, opts)
      if ok then return end
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
      if file._closed_completion:_is_pending() then publish(rt, file._closed_completion, false, failure) end
      if not Runtime.is_cancelled(err) then error(failure, 0) end
    end,
  })
end

function File.submit_open_op(path, mode, opts)
  path, mode = validate_path(path, 'submit_open_op'), validate_mode(mode)
  return new_file_op(path, mode, opts, 'file.submit_open_op', false)
end
function File.open_op(path, mode, opts)
  path, mode = validate_path(path, 'open_op'), validate_mode(mode)
  local submission = new_file_op(path, mode, opts, 'file.open_op', false)
  return submission:wrap(function(file, err)
    if not file then return nil, err end
    local ready, ready_err = file:ready()
    if not ready then return nil, ready_err end
    return file
  end)
end
function File.submit_tmpfile_op(opts)
  return new_file_op('', 'w+b', opts, 'file.submit_tmpfile_op', true)
end
function File.tmpfile_op(opts)
  local submission = new_file_op('', 'w+b', opts, 'file.tmpfile_op', true)
  return submission:wrap(function(file, err)
    if not file then return nil, err end
    local ready, ready_err = file:ready()
    if not ready then return nil, ready_err end
    return file
  end)
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
  local submission = IO.admit_driven_lifetime_op(scope, job, {
    operation = operation,
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
