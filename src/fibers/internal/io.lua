-- Shared implementation helpers for host-backed facilities.
--
-- This module is internal. It centralises ownership resolution, structured
-- driver construction, masked option performance during short adoption
-- intervals, and conversion of host handles into Streams.

local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')
local Task = require('fibers.task')
local HostError = require('fibers.host.error')
local Protected = require('fibers.internal.protected')

local IO = {}

function IO.copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function IO.region_of(owner)
  if owner and owner._fibers_scope and type(owner.raw_region) == 'function' then
    return owner:raw_region()
  end
  if owner and type(owner.admit_op) == 'function' and type(owner.release_op) == 'function' then
    return owner
  end
  return nil
end

function IO.current_owner(opts, label)
  opts = opts or {}
  local owner = opts.owner or Runtime.current_scope()
  if not owner then
    error(label .. ' requires opts.owner or a current Scope', 3)
  end
  if type(owner.admit_op) ~= 'function' then
    error(label .. ' owner must be a Scope or Region', 3)
  end
  return owner
end

function IO.scope_for_owner(owner, label)
  if owner and owner._fibers_scope then
    return owner
  end
  local region = IO.region_of(owner)
  local scope = region and region._fibers_scope_owner or nil
  if scope and scope._fibers_scope then
    return scope
  end
  error(label .. ' owner Region must belong to a Scope so its driver has a structured execution scope', 3)
end

function IO.masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

function IO.new_driver_task(owner, name, fn)
  return Task.new(function(task_handle)
    return owner:_run_child_body(fn, task_handle, { name = name })
  end, name, owner)
end

function IO.close_value(domain, value, reason)
  if value and type(value.close) == 'function' then
    return value:close(reason)
  end
  return nil, HostError.unsupported(domain, 'close')
end

function IO.protocol_error(domain, action, err, fields)
  fields = fields or {}
  fields.cause = fields.cause or err
  return HostError.protocol(domain, action, tostring(err), fields)
end

function IO.safe_close(domain, value, reason, fields)
  fields = fields or {}
  local ok, closed, err = Protected.pcall(IO.close_value, domain, value, reason)
  if not ok then
    return nil, IO.protocol_error(domain, fields.action or 'close', closed, fields)
  end
  if not closed then
    return nil, HostError.normalise(err, fields)
  end
  return true
end

function IO.release_owned(rt, region, record)
  local ok, err = Protected.pcall(function()
    return IO.masked_perform(rt, region:release_op(record))
  end)
  if not ok then
    return nil, err
  end
  return true
end

function IO.open_handle_stream(rt, owner, handle, opts)
  return IO.masked_perform(
    rt,
    Stream.open_op(handle, {
      owner = owner,
      name = opts.name,
      read = opts.read == true,
      write = opts.write == true,
      read_capacity = opts.read_capacity or opts.capacity,
      write_capacity = opts.write_capacity or opts.capacity,
      read_chunk_size = opts.read_chunk_size or opts.chunk_size,
      write_chunk_size = opts.write_chunk_size or opts.chunk_size,
    })
  )
end

return IO
