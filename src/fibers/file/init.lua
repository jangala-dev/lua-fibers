-- File and pipe facilities.
--
-- Anonymous pipes use readiness-backed Streams. Regular files use the
-- runtime-only evented job service exported by fibers.file.regular.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Acquired = require('fibers.io.internal.acquired')
local IO = require('fibers.io.facility')
local Protected = require('fibers.protected')
local Direct = require('fibers.internal.direct')
local Regular = require('fibers.file.regular')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local File = {}

local PIPE_OPTIONS = {
  scope = true, host = true, label = true, capacity = true,
  read_capacity = true, write_capacity = true, chunk_size = true,
  read_chunk_size = true, write_chunk_size = true,
}

local function close_pipe_handle(handle, reason)
  return IO.close_value('pipe', handle, reason)
end

local function acquire_handles(rt, opts)
  local host = opts.host or rt.host
  if not host or type(host.create_pipe) ~= 'function' then
    return nil, nil, IOError.unsupported('host', 'pipe', {
      host = host and Label.describe(host, host.kind or host.family) or nil,
    })
  end

  local read_handle, write_handle, err, detail = host:create_pipe({
    label = opts.label,
    nonblocking = true,
  })
  if not read_handle or not write_handle then
    local primary = IOError.normalise(err or detail or 'pipe creation failed', {
      domain = 'pipe',
      action = 'create',
      detail = detail,
    })
    local cleanup_errors = {}
    if read_handle then
      IOError.capture_cleanup(cleanup_errors, 'pipe', 'partial_read_close', nil, close_pipe_handle, read_handle, primary)
    end
    if write_handle then
      IOError.capture_cleanup(cleanup_errors, 'pipe', 'partial_write_close', nil, close_pipe_handle, write_handle, primary)
    end
    return nil, nil, IOError.with_cleanup(
      primary, 'pipe', 'create',
      'pipe creation failed and partial host-handle cleanup was incomplete',
      cleanup_errors
    )
  end
  return read_handle, write_handle
end

local function endpoint_op(scope, handle, mode, opts)
  return IO.handle_stream_op(scope, handle, {
    label = opts.label and (opts.label .. ':' .. mode) or nil,
    read = mode == 'read', write = mode == 'write',
  }, opts)
end

local function setup_error(acquired, err)
  local closed, close_err = acquired:close(err)
  if closed then return nil, nil, err end
  return nil, nil, IOError.with_cleanup(
    err, 'pipe', 'start', 'pipe start failed and cleanup was incomplete', { close_err })
end

local function start_pipe(rt, scope, opts)
  local read_handle, write_handle, err = acquire_handles(rt, opts)
  if not read_handle then return nil, nil, err end
  local acquired = Acquired.new()
  acquired:hold('read', read_handle, close_pipe_handle)
  acquired:hold('write', write_handle, close_pipe_handle)

  local opened, streams = Protected.pcall(function()
    return IO.masked_perform(rt, Op.named_together({
      read = endpoint_op(scope, read_handle, 'read', opts),
      write = endpoint_op(scope, write_handle, 'write', opts),
    }))
  end)
  if not opened then
    return setup_error(acquired, IOError.normalise(streams, { domain = 'pipe', action = 'open_streams' }))
  end
  acquired:release('read', read_handle)
  acquired:release('write', write_handle)
  return streams.read, streams.write
end

function File.pipe_op(opts)
  opts = Contract.options(opts, PIPE_OPTIONS, 'file.pipe_op options', 2)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'file.pipe_op opts.label', 2) end
  for _, key in ipairs({ 'chunk_size', 'read_chunk_size', 'write_chunk_size' }) do
    if opts[key] ~= nil then Contract.positive_integer(opts[key], 'file.pipe_op opts.' .. key, 2) end
  end
  local scope = IO.current_scope(opts, 'file.pipe_op')
  return Op.always(true):wrap(function()
    local rt = Runtime.current()
    if not rt then error('file.pipe_op committed without a current runtime', 2) end
    return start_pipe(rt, scope, opts)
  end)
end

File.Error, File.RegularFile, File.Command, File.Job = IOError, Regular.RegularFile, Regular.Command, Regular.Job
for _, name in ipairs({
  'submit_open_op', 'open_op', 'open', 'submit_tmpfile_op', 'tmpfile_op', 'tmpfile',
  'submit_read_all_op', 'read_all_op', 'read_all', 'submit_write_all_op', 'write_all_op', 'write_all',
  'submit_rename_op', 'rename_op', 'rename', 'submit_unlink_op', 'unlink_op', 'unlink',
  'submit_mkdir_op', 'mkdir_op', 'mkdir', 'submit_mkdir_p_op', 'mkdir_p_op', 'mkdir_p',
}) do File[name] = Regular[name] end

Direct.install_static(File, { 'pipe' })

return File
