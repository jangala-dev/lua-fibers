-- File and pipe facilities.
--
-- Version 1 begins with anonymous pipes.  Regular files will use a separate
-- host-job path because readiness does not make regular-file calls non-blocking.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')
local HandleBackend = require('fibers.stream.backend.handle')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.internal.adoption')
local Completion = require('fibers.internal.completion')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local File = {}
local Pipe = {}
Pipe.__index = Pipe
local next_pipe = 0

local function region_of(owner)
  if owner and owner._fibers_scope and type(owner.raw_region) == 'function' then
    return owner:raw_region()
  end
  if owner and type(owner.admit_op) == 'function' and type(owner.release_op) == 'function' then
    return owner
  end
  return nil
end

local function admit_op(owner, owned)
  if not owner or type(owner.admit_op) ~= 'function' then
    error('file.pipe_op owner must be a Scope or Region', 3)
  end
  return owner:admit_op(owned)
end

local function masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

local function release_slot(rt, pipe, which)
  local active_key = which .. '_slot_active'
  if not pipe[active_key] then
    return true
  end
  local slot = pipe[which .. '_slot']
  local ok, err = Protected.pcall(function()
    return masked_perform(rt, pipe.region:release_op(slot))
  end)
  if not ok then
    return nil, err
  end
  pipe[active_key] = false
  return true
end

local function publish_failure(rt, completion, err)
  Protected.pcall(function()
    masked_perform(rt, completion:publish_failure_op(err))
  end)
end

local function close_handle(handle, reason)
  if handle and type(handle.close) == 'function' then
    return handle:close(reason)
  end
  return nil, HostError.unsupported('pipe', 'close')
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
      close_handle(read_handle, 'partial pipe acquisition')
    end
    if write_handle then
      close_handle(write_handle, 'partial pipe acquisition')
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
  local backend = HandleBackend.new(handle, {
    name = opts.name .. ':' .. mode .. ':backend',
  })
  return masked_perform(
    rt,
    Stream.open_op(backend, {
      owner = owner,
      name = opts.name .. ':' .. mode,
      read = mode == 'read',
      write = mode == 'write',
      read_capacity = opts.read_capacity or opts.capacity,
      write_capacity = opts.write_capacity or opts.capacity,
      read_chunk_size = opts.read_chunk_size or opts.chunk_size,
      write_chunk_size = opts.write_chunk_size or opts.chunk_size,
    })
  )
end

local function fail_start(rt, pipe, err)
  if pipe.read_stream then
    Protected.pcall(function()
      masked_perform(rt, pipe.read_stream:abort_op(err))
    end)
  end
  if pipe.write_stream then
    Protected.pcall(function()
      masked_perform(rt, pipe.write_stream:abort_op(err))
    end)
  end
  pipe.read_slot:close(err)
  pipe.write_slot:close(err)
  release_slot(rt, pipe, 'read')
  release_slot(rt, pipe, 'write')
  publish_failure(rt, pipe.completion, err)
  pipe.start_error = err
  return nil, err
end

function Pipe:_start(rt, opts)
  local read_handle, write_handle, acquire_err = acquire_handles(rt, opts)
  if not read_handle then
    return fail_start(rt, self, acquire_err)
  end

  local adopted, adopt_err =
    Adoption.adopt_pair(self.read_slot, self.write_slot, read_handle, write_handle, close_handle)
  if not adopted then
    return fail_start(rt, self, adopt_err)
  end

  local ok_read, read_stream_or_err = Protected.pcall(function()
    return open_endpoint(rt, self.owner, read_handle, 'read', opts)
  end)
  if not ok_read then
    return fail_start(
      rt,
      self,
      HostError.normalise(read_stream_or_err, {
        domain = 'pipe',
        action = 'open_read_stream',
      })
    )
  end
  self.read_stream = read_stream_or_err
  local transferred, transfer_err = self.read_slot:release(read_handle)
  if not transferred then
    return fail_start(
      rt,
      self,
      HostError.normalise(transfer_err, {
        domain = 'pipe',
        action = 'transfer_read_adoption',
      })
    )
  end
  local released, release_err = release_slot(rt, self, 'read')
  if not released then
    return fail_start(
      rt,
      self,
      HostError.normalise(release_err, {
        domain = 'pipe',
        action = 'release_read_adoption',
      })
    )
  end

  local ok_write, write_stream_or_err = Protected.pcall(function()
    return open_endpoint(rt, self.owner, write_handle, 'write', opts)
  end)
  if not ok_write then
    return fail_start(
      rt,
      self,
      HostError.normalise(write_stream_or_err, {
        domain = 'pipe',
        action = 'open_write_stream',
      })
    )
  end
  self.write_stream = write_stream_or_err
  transferred, transfer_err = self.write_slot:release(write_handle)
  if not transferred then
    return fail_start(
      rt,
      self,
      HostError.normalise(transfer_err, {
        domain = 'pipe',
        action = 'transfer_write_adoption',
      })
    )
  end
  released, release_err = release_slot(rt, self, 'write')
  if not released then
    return fail_start(
      rt,
      self,
      HostError.normalise(release_err, {
        domain = 'pipe',
        action = 'release_write_adoption',
      })
    )
  end

  self.started = true
  masked_perform(rt, self.completion:publish_success_op(self))
  return self
end

function Pipe:reader()
  return self.read_stream
end

function Pipe:writer()
  return self.write_stream
end

function Pipe:result_op()
  return self.completion:result_op()
end

function Pipe:close_op(reason)
  -- Closing the aggregate Pipe is abortive in both directions.  Graceful EOF is
  -- directional: close the writer Stream, drain the reader, then close it.
  return self:abort_op(reason)
end

function Pipe:abort_op(reason)
  if not self.read_stream and not self.write_stream then
    return Op.always(true)
  end
  return Op.always(true):wrap(function()
    local rt = Runtime.current()
    if not rt then
      error('Pipe closure requires a current runtime', 2)
    end
    local first_error
    for _, stream in ipairs({ self.read_stream, self.write_stream }) do
      if stream then
        local ok, err = masked_perform(rt, stream:abort_op(reason))
        if not ok and not first_error then
          first_error = err
        end
      end
    end
    if first_error then
      return nil, first_error
    end
    return true
  end)
end

local function closed_result_op(stream)
  return stream:closed_op():map(function(ok, err)
    return { ok = ok, error = err }
  end)
end

function Pipe:closed_op()
  local entries = {}
  if self.read_stream then
    entries[#entries + 1] = { 'read', closed_result_op(self.read_stream) }
  end
  if self.write_stream then
    entries[#entries + 1] = { 'write', closed_result_op(self.write_stream) }
  end
  if #entries == 0 then
    return Op.always(self.start_error == nil, self.start_error)
  end
  return Op.named_all(entries):map(function(results)
    for _, direction in ipairs({ 'read', 'write' }) do
      local result = results[direction]
      if result and not result.ok then
        return nil, result.error
      end
    end
    return true
  end)
end

function File.pipe_op(opts)
  opts = opts or {}
  next_pipe = next_pipe + 1
  local name = opts.name or ('pipe-' .. tostring(next_pipe))
  local owner = opts.owner or Runtime.current_scope()
  if not owner then
    error('file.pipe_op requires opts.owner or a current Scope', 2)
  end
  local region = region_of(owner)
  if not region then
    error('file.pipe_op owner must be a Scope or Region', 2)
  end

  local pipe = setmetatable({
    name = name,
    owner = owner,
    region = region,
    completion = Completion.new(name .. ':completion'),
    read_slot = Adoption.slot(name .. ':read-adoption'),
    write_slot = Adoption.slot(name .. ':write-adoption'),
    read_stream = nil,
    write_stream = nil,
    started = false,
    start_error = nil,
    read_slot_active = true,
    write_slot_active = true,
  }, Pipe)

  return admit_op(owner, pipe.read_slot:owned({ role = 'pipe_read_adoption' }))
    :and_then(function()
      return admit_op(owner, pipe.write_slot:owned({ role = 'pipe_write_adoption' }))
    end)
    :wrap(function()
      local rt = Runtime.current()
      if not rt then
        error('file.pipe_op committed without a current runtime', 2)
      end
      local started, err = pipe:_start(rt, {
        host = opts.host,
        name = name,
        capacity = opts.capacity,
        read_capacity = opts.read_capacity,
        write_capacity = opts.write_capacity,
        chunk_size = opts.chunk_size,
        read_chunk_size = opts.read_chunk_size,
        write_chunk_size = opts.write_chunk_size,
      })
      if not started then
        return nil, nil, err
      end
      return started:reader(), started:writer()
    end)
end

-- Pipe is intentionally internal to the acquisition and settlement protocol.
-- Public callers receive the readable and writable Streams directly.
File._Pipe = Pipe
File.Error = HostError
function File.pipe(opts)
  return perform(File.pipe_op(opts))
end

return File
