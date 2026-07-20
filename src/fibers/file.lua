-- File and pipe facilities.
--
-- Version 1 begins with anonymous pipes. Regular files will use a separate
-- host-job path because readiness does not make regular-file calls non-blocking.

local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.internal.adoption')
local IO = require('fibers.internal.io')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local File = {}
local next_pipe = 0

local function close_pipe_handle(handle, reason)
  return IO.close_value('pipe', handle, reason)
end

local function release_slot(rt, start, which)
  local active_key = which .. '_slot_active'
  if not start[active_key] then
    return true
  end
  local slot = start[which .. '_slot']
  local ok, err = IO.release_owned(rt, start.region, slot)
  if not ok then
    return nil, err
  end
  start[active_key] = false
  return true
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

local function open_endpoint(rt, owner, handle, mode, opts)
  return IO.open_handle_stream(rt, owner, handle, {
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
  start.read_slot:close(err)
  start.write_slot:close(err)
  release_slot(rt, start, 'read')
  release_slot(rt, start, 'write')
  return nil, nil, err
end

local function start_pipe(rt, start, opts)
  local read_handle, write_handle, acquire_err = acquire_handles(rt, opts)
  if not read_handle then
    return fail_start(rt, start, acquire_err)
  end

  local adopted, adopt_err =
    Adoption.adopt_pair(start.read_slot, start.write_slot, read_handle, write_handle, close_pipe_handle)
  if not adopted then
    return fail_start(rt, start, adopt_err)
  end

  local ok_read, read_stream_or_err = Protected.pcall(function()
    return open_endpoint(rt, start.owner, read_handle, 'read', opts)
  end)
  if not ok_read then
    return fail_start(
      rt,
      start,
      HostError.normalise(read_stream_or_err, {
        domain = 'pipe',
        action = 'open_read_stream',
      })
    )
  end
  start.read_stream = read_stream_or_err

  local transferred, transfer_err = start.read_slot:release(read_handle)
  if not transferred then
    return fail_start(
      rt,
      start,
      HostError.normalise(transfer_err, {
        domain = 'pipe',
        action = 'transfer_read_adoption',
      })
    )
  end

  local released, release_err = release_slot(rt, start, 'read')
  if not released then
    return fail_start(
      rt,
      start,
      HostError.normalise(release_err, {
        domain = 'pipe',
        action = 'release_read_adoption',
      })
    )
  end

  local ok_write, write_stream_or_err = Protected.pcall(function()
    return open_endpoint(rt, start.owner, write_handle, 'write', opts)
  end)
  if not ok_write then
    return fail_start(
      rt,
      start,
      HostError.normalise(write_stream_or_err, {
        domain = 'pipe',
        action = 'open_write_stream',
      })
    )
  end
  start.write_stream = write_stream_or_err

  transferred, transfer_err = start.write_slot:release(write_handle)
  if not transferred then
    return fail_start(
      rt,
      start,
      HostError.normalise(transfer_err, {
        domain = 'pipe',
        action = 'transfer_write_adoption',
      })
    )
  end

  released, release_err = release_slot(rt, start, 'write')
  if not released then
    return fail_start(
      rt,
      start,
      HostError.normalise(release_err, {
        domain = 'pipe',
        action = 'release_write_adoption',
      })
    )
  end

  return start.read_stream, start.write_stream
end

function File.pipe_op(opts)
  opts = opts or {}
  next_pipe = next_pipe + 1
  local name = opts.name or ('pipe-' .. tostring(next_pipe))
  local owner = IO.current_owner(opts, 'file.pipe_op')
  local region = IO.region_of(owner)
  if not region then
    error('file.pipe_op owner must be a Scope or Region', 2)
  end

  local start = {
    owner = owner,
    region = region,
    read_slot = Adoption.slot(name .. ':read-adoption'),
    write_slot = Adoption.slot(name .. ':write-adoption'),
    read_stream = nil,
    write_stream = nil,
    read_slot_active = true,
    write_slot_active = true,
  }

  return owner
    :admit_op(start.read_slot:owned({ role = 'pipe_read_adoption' }))
    :and_then(function()
      return owner:admit_op(start.write_slot:owned({ role = 'pipe_write_adoption' }))
    end)
    :wrap(function()
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

function File.pipe(opts) return perform(File.pipe_op(opts)) end

return File
