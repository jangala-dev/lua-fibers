-- Host-handle integration for portable Streams.
--
-- The Stream value and all byte-flow behaviour live in `fibers.stream`. This
-- module adds reactor registration and transactional admission of host handles.

local Op = require('fibers.op')
local Flow = require('fibers.resource.flow')
local Reactor = require('fibers.io.reactor')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local HostStream = {}
setmetatable(HostStream, { __index = Stream })

local OPEN_OPTIONS = {
  scope = true, label = true, read = true, write = true,
  read_capacity = true, write_capacity = true,
  read_chunk_size = true, write_chunk_size = true,
}

local function host_stream(label, opts)
  local read_flow = opts.read and Flow.new(opts.read_capacity):label(label .. ':rx') or nil
  local write_flow = opts.write and Flow.new(opts.write_capacity):label(label .. ':tx') or nil
  local stream = Stream.compose(read_flow, write_flow, {
    label = label,
    mode = opts.read and opts.write and 'duplex' or (opts.read and 'reader' or 'writer'),
    kind = 'host_stream',
  })
  stream._handle, stream._reactor = opts.handle, opts.reactor
  stream._read_chunk_size, stream._write_chunk_size = opts.read_chunk_size, opts.write_chunk_size
  return stream
end

local function endpoint(stream, side)
  if side == 'read' then
    return stream:reader()
  end
  return stream:writer()
end

local function attach_direction(stream, side, reactor, handle, registrations, children)
  local ep = endpoint(stream, side)
  if not ep then return end
  local registration = reactor:direction({
    label = Label.describe(stream, stream._fibers_id or 'stream') .. ':' .. side,
    mode = side,
    stream = stream,
    flow = ep._flow,
    handle = handle,
    chunk_size = side == 'read' and stream._read_chunk_size or stream._write_chunk_size,
  })
  stream['_' .. side .. '_registration'] = registration
  children[#children + 1] = registration
  registrations[side .. '_registration'] = registration:register_op()
end

local function open_in_op(scope, handle, opts)
  opts = Contract.options(opts, OPEN_OPTIONS, 'Stream.open_op options', 3)
  if not (scope and scope._fibers_scope) then
    error('Stream.open_op scope must be a Scope', 3)
  end
  if type(handle) ~= 'table' or handle._fibers_host_handle ~= true then
    error('Stream.open_op expects a HostHandle', 3)
  end
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'Stream.open_op opts.label', 3) end
  if type(opts.read) ~= 'boolean' or type(opts.write) ~= 'boolean' then
    error('Stream.open_op requires explicit boolean opts.read and opts.write', 3)
  end
  if not opts.read and not opts.write then
    error('Stream.open_op requires an enabled direction', 3)
  end
  for _, capability in ipairs({ opts.read and 'read', opts.write and 'write', 'readiness', 'close' }) do
    if capability and not handle:supports(capability) then
      error('Stream HostHandle requires ' .. capability .. ' capability', 3)
    end
  end
  local runtime = Runtime.current()
  if not runtime then
    error('Stream.open_op requires a current runtime', 3)
  end
  local label = opts.label or Label.describe(handle, handle._fibers_id or 'host-stream')
  local reactor = Reactor.for_runtime(runtime)
  local stream = host_stream(label, {
    handle = handle,
    reactor = reactor,
    read = opts.read,
    write = opts.write,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
    read_chunk_size = opts.read_chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or 4096,
  })
  local registrations, children = {}, {}
  attach_direction(stream, 'read', reactor, handle, registrations, children)
  attach_direction(stream, 'write', reactor, handle, registrations, children)
  stream._reactor_live = #children
  for i = 1, #children do stream._lifetime:add_child(children[i]) end
  return scope:admit_op(stream):and_then(Op.named_each(registrations):map(function()
      return stream
    end))
end

function HostStream.open_op(handle, opts)
  opts = Contract.options(opts, OPEN_OPTIONS, 'Stream.open_op options', 2)
  local scope = opts.scope or (Runtime.current_scope and Runtime.current_scope())
  if not scope then
    error('Stream.open_op requires opts.scope or a current Scope', 2)
  end
  return open_in_op(scope, handle, opts)
end

return HostStream
