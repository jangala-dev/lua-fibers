-- File and pipe facilities.
--
-- Anonymous pipes use readiness-backed Streams. Regular files use the
-- runtime-only evented job service exported by fibers.file.regular.

local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local HostHold = require('fibers.internal.lifetime.host_hold')
local IO = require('fibers.host.io')
local Protected = require('fibers.protected')
local perform = require('fibers.perform')
local Regular = require('fibers.file.regular')

local File = {}
local next_pipe = 0

local function close_pipe_handle(handle, reason)
  return IO.close_value('pipe', handle, reason)
end

local function acquire_handles(rt, opts)
  local host = opts.host or rt.host
  if not host or type(host.create_pipe) ~= 'function' then
    return nil, nil, HostError.unsupported('host', 'pipe', {
      host = host and host.name or nil,
    })
  end

  local read_handle, write_handle, err, detail = host:create_pipe({
    name = opts.name,
    nonblocking = true,
  })
  if not read_handle or not write_handle then
    if read_handle then
      close_pipe_handle(read_handle, 'partial pipe acquisition')
    end
    if write_handle then
      close_pipe_handle(write_handle, 'partial pipe acquisition')
    end
    return nil,
      nil,
      HostError.normalise(err or detail or 'pipe creation failed', {
        domain = 'pipe',
        action = 'create',
        detail = detail,
      })
  end
  return read_handle, write_handle
end

local function open_endpoint(rt, scope, handle, mode, opts)
  return IO.open_handle_stream(rt, scope, handle, {
    name = opts.name .. ':' .. mode,
    read = mode == 'read',
    write = mode == 'write',
    capacity = opts.capacity,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
    chunk_size = opts.chunk_size,
    read_chunk_size = opts.read_chunk_size,
    write_chunk_size = opts.write_chunk_size,
  })
end

local function fail_start(rt, start, err)
  if start.read_stream then
    Protected.pcall(function()
      IO.masked_perform(rt, start.read_stream:abort_op(err))
    end)
  end
  if start.write_stream then
    Protected.pcall(function()
      IO.masked_perform(rt, start.write_stream:abort_op(err))
    end)
  end
  start.host_hold:close(err)
  return nil, nil, err
end

local function finish_endpoint(rt, start, which, handle, opts)
  local ok, stream = Protected.pcall(function()
    return open_endpoint(rt, start.scope, handle, which, opts)
  end)
  if not ok then
    return nil,
      HostError.normalise(stream, {
        domain = 'pipe',
        action = 'open_' .. which .. '_stream',
      })
  end
  start[which .. '_stream'] = stream

  local transferred, transfer_err = start.host_hold:release(which, handle)
  if not transferred then
    return nil,
      HostError.normalise(transfer_err, {
        domain = 'pipe',
        action = 'transfer_' .. which .. '_host_hold',
      })
  end
  return stream
end

local function start_pipe(rt, start, opts)
  local read_handle, write_handle, err = acquire_handles(rt, opts)
  if not read_handle then
    return fail_start(rt, start, err)
  end

  local held, hold_err = start.host_hold:hold_many({
    { key = 'read', value = read_handle, close = close_pipe_handle },
    { key = 'write', value = write_handle, close = close_pipe_handle },
  })
  if not held then
    return fail_start(rt, start, hold_err)
  end

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
  opts = opts or {}
  next_pipe = next_pipe + 1
  local name = opts.name or ('pipe-' .. tostring(next_pipe))
  local scope = IO.current_scope(opts, 'file.pipe_op')
  local start = {
    scope = scope,
    host_hold = HostHold.new(name .. ':host-hold'),
    read_stream = nil,
    write_stream = nil,
  }

  return scope:admit_op(start.host_hold):wrap(function()
    local rt = Runtime.current()
    if not rt then
      error('file.pipe_op committed without a current runtime', 2)
    end
    return start_pipe(rt, start, {
      host = opts.host,
      name = name,
      capacity = opts.capacity,
      read_capacity = opts.read_capacity,
      write_capacity = opts.write_capacity,
      chunk_size = opts.chunk_size,
      read_chunk_size = opts.read_chunk_size,
      write_chunk_size = opts.write_chunk_size,
    })
  end)
end

File.Error = HostError
File.RegularFile = Regular.RegularFile
File.Request = Regular.Request
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

function File.pipe(opts)
  return perform(File.pipe_op(opts))
end

return File
