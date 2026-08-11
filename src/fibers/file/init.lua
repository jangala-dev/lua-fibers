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

local function open_endpoint(rt, scope, handle, mode, opts)
  return IO.open_handle_stream(rt, scope, handle, {
    label = opts.label and (opts.label .. ':' .. mode) or nil,
    read = mode == 'read', write = mode == 'write',
  }, opts)
end

local function fail_start(rt, start, err)
  local cleanup_errors = {}
  if start.read_stream then
    IOError.capture_cleanup(cleanup_errors, 'pipe', 'abort_read_stream', nil, function()
      return IO.masked_perform(rt, start.read_stream:abort_op(err))
    end)
  end
  if start.write_stream then
    IOError.capture_cleanup(cleanup_errors, 'pipe', 'abort_write_stream', nil, function()
      return IO.masked_perform(rt, start.write_stream:abort_op(err))
    end)
  end
  IOError.capture_cleanup(cleanup_errors, 'pipe', 'close_acquired', nil, start.acquired.close, start.acquired, err)
  return nil, nil, IOError.with_cleanup(
    err, 'pipe', 'start',
    'pipe start failed and cleanup was incomplete',
    cleanup_errors
  )
end

local function finish_endpoint(rt, start, which, handle, opts)
  local ok, stream = Protected.pcall(function()
    return open_endpoint(rt, start.scope, handle, which, opts)
  end)
  if not ok then
    return nil,
      IOError.normalise(stream, {
        domain = 'pipe',
        action = 'open_' .. which .. '_stream',
      })
  end
  start[which .. '_stream'] = stream

  start.acquired:release(which, handle)
  return stream
end

local function start_pipe(rt, start, opts)
  local read_handle, write_handle, err = acquire_handles(rt, opts)
  if not read_handle then
    return fail_start(rt, start, err)
  end

  start.acquired:hold('read', read_handle, close_pipe_handle)
  start.acquired:hold('write', write_handle, close_pipe_handle)

  local read_stream, read_err = finish_endpoint(rt, start, 'read', read_handle, opts)
  if not read_stream then
    return fail_start(rt, start, read_err)
  end
  local write_stream, write_err = finish_endpoint(rt, start, 'write', write_handle, opts)
  if not write_stream then
    return fail_start(rt, start, write_err)
  end
  return read_stream, write_stream
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
    return start_pipe(rt, {
      scope = scope, acquired = Acquired.new(),
      read_stream = nil, write_stream = nil,
    }, opts)
  end)
end

File.Error = IOError
File.RegularFile = Regular.RegularFile
File.Command = Regular.Command
File.Job = Regular.Job
File.submit_open_op = Regular.submit_open_op
File.open_op = Regular.open_op
File.open = Regular.open
File.submit_tmpfile_op = Regular.submit_tmpfile_op
File.tmpfile_op = Regular.tmpfile_op
File.tmpfile = Regular.tmpfile
File.submit_read_all_op = Regular.submit_read_all_op
File.read_all_op = Regular.read_all_op
File.read_all = Regular.read_all
File.submit_write_all_op = Regular.submit_write_all_op
File.write_all_op = Regular.write_all_op
File.write_all = Regular.write_all
File.submit_rename_op = Regular.submit_rename_op
File.rename_op = Regular.rename_op
File.rename = Regular.rename
File.submit_unlink_op = Regular.submit_unlink_op
File.unlink_op = Regular.unlink_op
File.unlink = Regular.unlink
File.submit_mkdir_op = Regular.submit_mkdir_op
File.mkdir_op = Regular.mkdir_op
File.mkdir = Regular.mkdir
File.submit_mkdir_p_op = Regular.submit_mkdir_p_op
File.mkdir_p_op = Regular.mkdir_p_op
File.mkdir_p = Regular.mkdir_p

Direct.install_static(File, { 'pipe' })

return File
