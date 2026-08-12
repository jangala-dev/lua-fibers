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
  local_address = true, peer_address = true,
}

local function host_stream(label, opts)
  local read_flow = opts.read and Flow.new(opts.read_capacity):label(label .. ':rx') or nil
  local write_flow = opts.write and Flow.new(opts.write_capacity):label(label .. ':tx') or nil
  local stream = Stream.compose(read_flow, write_flow, {
    label = label,
    mode = opts.read and opts.write and 'duplex' or (opts.read and 'reader' or 'writer'),
    kind = 'host_stream',
  })
  stream._handle = opts.handle
  return stream
end

local function endpoint(stream, side)
  if side == 'read' then
    return stream:reader()
  end
  return stream:writer()
end

local function attach_direction(stream, side, reactor, handle, chunk_size, registrations, children)
  local ep = endpoint(stream, side)
  if not ep then return end
  local registration = reactor:direction({
    label = Label.describe(stream, stream._fibers_id or 'stream') .. ':' .. side,
    mode = side,
    stream = stream,
    flow = ep._flow,
    handle = handle,
    chunk_size = chunk_size,
  })
  stream['_' .. side .. '_registration'] = registration
  children[#children + 1] = registration
  registrations[side .. '_registration'] = registration:register_op()
end

function HostStream.open_op(handle, opts)
  opts = Contract.options(opts, OPEN_OPTIONS, 'Stream.open_op options', 2)
  local scope = opts.scope or (Runtime.current_scope and Runtime.current_scope())
  if not scope then error('Stream.open_op requires opts.scope or a current Scope', 2) end
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
  -- Option elaboration may occur inside Op.guard, where there is deliberately no
  -- participant Runtime.current().  A target Scope is already bound before it can
  -- own a host Stream, so use that structural binding.  Creating the Runtime's
  -- reactor remains a participant-side action; speculative elaboration may only
  -- reuse the reactor which the surrounding host facility has already established.
  local current = Runtime.current()
  local runtime = current or (scope._lifetime and scope._lifetime._runtime)
  if not runtime then
    error('Stream.open_op requires a runtime-bound Scope', 3)
  end
  local label = opts.label or Label.describe(handle, handle._fibers_id or 'host-stream')
  local reactor = runtime.host_reactor
  if not reactor then
    if current ~= runtime then
      error('Stream.open_op cannot create a host reactor during speculative elaboration', 3)
    end
    reactor = Reactor.for_runtime(runtime)
  end
  local stream = host_stream(label, {
    handle = handle,
    read = opts.read,
    write = opts.write,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
  })
  if opts.local_address ~= nil or opts.peer_address ~= nil then
    stream:_set_addresses(opts.local_address, opts.peer_address)
  end
  local registrations, children = {}, {}
  attach_direction(stream, 'read', reactor, handle, opts.read_chunk_size or 4096, registrations, children)
  attach_direction(stream, 'write', reactor, handle, opts.write_chunk_size or 4096, registrations, children)
  for i = 1, #children do stream._lifetime:add_child(children[i]) end
  return scope:admit_op(stream):and_then(Op.named_each(registrations):map(function()
      return stream
    end))
end

return HostStream
