-- Streams are capability-shaped compositions of unidirectional byte Flows.
--
-- A Stream adds no byte state of its own.  It pairs an optional Flow Outlet
-- with an optional Flow Inlet, composes their lifecycle operations, and, for
-- host handles, arranges reactor registrations around those same Flows.

local Op = require('fibers.op')
local Flow = require('fibers.resource.flow')
local Reactor = require('fibers.host.reactor')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local Runtime = require('fibers.runtime')
local perform = require('fibers.perform')

local Stream, Duplex = {}, {}
Duplex.__index = Duplex
local next_id = 0

local function validate_options(opts, allowed, label)
  for key in pairs(opts or {}) do
    if not allowed[key] then
      error((label or 'options') .. ' does not accept ' .. tostring(key), 3)
    end
  end
end

local function compose(opts)
  opts = opts or {}
  next_id = next_id + 1
  local name = opts.name or ('stream-' .. tostring(next_id))
  local stream = setmetatable({
    name = name,
    kind = opts.kind or 'stream',
    mode = opts.mode or 'composed',
    _reader = opts.reader,
    _writer = opts.writer,
    handle = opts.handle,
    reactor = opts.reactor,
    read_registration = nil,
    write_registration = nil,
    _reactor_live = 0,
    _handle_closed = false,
  }, Duplex)
  local children = {}
  if opts.reader then
    children[#children + 1] = opts.reader
  end
  if opts.writer then
    children[#children + 1] = opts.writer
  end
  Lifetime.define(stream, {
    role = opts.kind or 'stream',
    closure = opts.closure or Closure.protocol({
      name = 'stream',
      finish_op = function(_ctx, record)
        return record.item:closed_op()
      end,
      finish_result = Closure.require_ok('stream closure failed'),
    }),
    children = children,
  })
  return stream
end

function Stream.compose(read_flow, write_flow, opts)
  opts = opts or {}
  if read_flow ~= nil and (type(read_flow) ~= 'table' or type(read_flow.outlet) ~= 'function') then
    error('Stream.compose read_flow must be a Flow or nil', 2)
  end
  if write_flow ~= nil and (type(write_flow) ~= 'table' or type(write_flow.inlet) ~= 'function') then
    error('Stream.compose write_flow must be a Flow or nil', 2)
  end
  if read_flow == nil and write_flow == nil then
    error('Stream.compose requires a readable or writable Flow', 2)
  end
  return compose({
    name = opts.name,
    mode = opts.mode,
    kind = opts.kind,
    reader = read_flow and read_flow:outlet(),
    writer = write_flow and write_flow:inlet(),
  })
end

function Duplex:reader()
  return self._reader
end
function Duplex:writer()
  return self._writer
end
function Duplex:is_readable()
  return self._reader ~= nil
end
function Duplex:is_writable()
  return self._writer ~= nil
end
function Duplex:is_duplex()
  return self._reader ~= nil and self._writer ~= nil
end
function Duplex:local_address()
  return self._local_address
end
function Duplex:peer_address()
  return self._peer_address
end
function Duplex:_set_addresses(local_address, peer_address)
  self._local_address, self._peer_address = local_address, peer_address
  return self
end
function Duplex:close_state()
  return {
    handle_closed = self._handle_closed == true,
    reactor_live = self._reactor_live or 0,
    close_error = self._close_error,
    readable = self:is_readable(),
    writable = self:is_writable(),
  }
end

local function side_endpoint(self, side)
  if side == 'read' then
    return self._reader
  end
  return self._writer
end

local function endpoint(self, side, level)
  local value = side_endpoint(self, side)
  if not value then
    error('stream is not ' .. (side == 'read' and 'readable' or 'writable'), level or 3)
  end
  return value
end

for _, name in ipairs({ 'read_some', 'read_exactly', 'read_until', 'read_line', 'read_all' }) do
  Duplex[name .. '_op'] = function(self, ...)
    return endpoint(self, 'read')[name .. '_op'](endpoint(self, 'read'), ...)
  end
  Duplex[name] = function(self, ...)
    return perform(self[name .. '_op'](self, ...))
  end
end

function Duplex:read_op(spec, opts)
  if type(spec) == 'number' then
    return self:read_some_op(spec)
  end
  if spec == '*l' or spec == '*L' then
    local line_opts = {}
    for key, value in pairs(opts or {}) do
      line_opts[key] = value
    end
    line_opts.keep_terminator = spec == '*L'
    return self:read_line_op(line_opts)
  end
  if spec == '*a' then
    return self:read_all_op(opts)
  end
  error("stream read_op expects a byte count, '*l', '*L' or '*a'", 2)
end
function Duplex:read(spec, opts)
  return perform(self:read_op(spec, opts))
end

local function write_bytes(...)
  local count = select('#', ...)
  if count == 0 then
    return ''
  end
  local parts = {}
  for i = 1, count do
    local part = select(i, ...)
    if type(part) ~= 'string' then
      error('stream write expects string arguments', 3)
    end
    parts[i] = part
  end
  return table.concat(parts)
end
function Duplex:write_op(...)
  return endpoint(self, 'write'):write_op(write_bytes(...))
end
function Duplex:write_some_op(bytes)
  return endpoint(self, 'write'):write_some_op(bytes)
end
function Duplex:flush_op()
  return endpoint(self, 'write'):flush_op()
end
for _, name in ipairs({ 'write', 'write_some', 'flush' }) do
  Duplex[name] = function(self, ...)
    return perform(self[name .. '_op'](self, ...))
  end
end

local function flow_of(value)
  return value and value.flow
end

local function retire_direction(self, side, reason, policy, abort)
  local ep = side_endpoint(self, side)
  if not ep then
    return Op.always(true)
  end
  local request = abort and flow_of(ep):abort_op(reason) or ep:close_op(reason)
  local registration = self[side .. '_registration']
  if registration then
    request = Op.tensor({ request, registration:retire_op(reason, policy) }):map(function()
      return true
    end)
  end
  return request
end
function Duplex:shutdown_read_op(reason)
  return retire_direction(self, 'read', reason, 'immediate', false)
end
function Duplex:shutdown_write_op(reason)
  return retire_direction(self, 'write', reason, 'drain', false)
end
function Duplex:abort_write_op(reason)
  return retire_direction(self, 'write', reason, 'abort', true)
end

local function close_request(self, reason, abort_write)
  local operations = {}
  if self._reader then
    operations[#operations + 1] = self:shutdown_read_op(reason)
  end
  if self._writer then
    operations[#operations + 1] = abort_write and self:abort_write_op(reason)
      or self:shutdown_write_op(reason)
  end
  return #operations == 0 and Op.always(true) or Op.tensor(operations):map(function()
    return true
  end)
end

local function wait_after_commit(self, request, before_wait)
  return request:wrap(function()
    local runtime = Runtime.current()
    if not runtime then
      error('Stream closure requires a current runtime', 2)
    end
    if before_wait then
      local ok, err = before_wait(runtime)
      if not ok then
        return nil, err
      end
    end
    return runtime:_perform_current(self:closed_op(), nil, true)
  end)
end
function Duplex:close_op(reason)
  return wait_after_commit(self, close_request(self, reason, false), function(runtime)
    return self._writer and runtime:_perform_current(self._writer:flush_op(), nil, true) or true
  end)
end
function Duplex:abort_op(reason)
  return wait_after_commit(self, close_request(self, reason, true))
end
function Duplex:closed_op()
  local operations = {}
  if self._reader then
    operations[#operations + 1] = self._reader:closed_op()
  end
  if self._writer then
    operations[#operations + 1] = self._writer:closed_op()
  end
  if self.read_registration then
    operations[#operations + 1] = self.read_registration:retired_op()
  end
  if self.write_registration then
    operations[#operations + 1] = self.write_registration:retired_op()
  end
  return Op.all(operations):map(function()
    if self._close_error then
      return nil, self._close_error
    end
    return true
  end)
end
for _, name in ipairs({ 'shutdown_read', 'shutdown_write', 'abort_write', 'close', 'abort', 'closed' }) do
  Duplex[name] = function(self, ...)
    return perform(self[name .. '_op'](self, ...))
  end
end

function Stream.memory_pair(opts)
  opts = opts or {}
  validate_options(opts, { name = true, capacity = true }, 'Stream.memory_pair options')
  local name = opts.name or 'memory-flow'
  local ab = Flow.new(opts.capacity, name .. ':a->b')
  local ba = Flow.new(opts.capacity, name .. ':b->a')
  return Stream.compose(ba, ab, { name = name .. ':a', mode = 'memory' }),
    Stream.compose(ab, ba, { name = name .. ':b', mode = 'memory' })
end

local function host_stream(name, opts)
  local read_flow = opts.read and Flow.new(opts.read_capacity, name .. ':rx') or nil
  local write_flow = opts.write and Flow.new(opts.write_capacity, name .. ':tx') or nil
  local stream = Stream.compose(read_flow, write_flow, {
    name = name,
    mode = opts.read and opts.write and 'duplex' or (opts.read and 'reader' or 'writer'),
    kind = 'host_stream',
  })
  stream.handle, stream.reactor = opts.handle, opts.reactor
  stream.read_chunk_size, stream.write_chunk_size = opts.read_chunk_size, opts.write_chunk_size
  return stream
end

local function attach_direction(stream, side, reactor, handle, registrations, children)
  local ep = side_endpoint(stream, side)
  if not ep then
    return
  end
  local registration = reactor:direction({
    name = stream.name .. ':' .. side,
    mode = side,
    stream = stream,
    flow = flow_of(ep),
    handle = handle,
    chunk_size = side == 'read' and stream.read_chunk_size or stream.write_chunk_size,
  })
  stream[side .. '_registration'] = registration
  children[#children + 1] = registration
  registrations[#registrations + 1] = { side .. '_registration', registration:register_op() }
end

local function open_in_op(scope, handle, opts)
  validate_options(opts, {
    scope = true,
    name = true,
    read = true,
    write = true,
    read_capacity = true,
    write_capacity = true,
    read_chunk_size = true,
    write_chunk_size = true,
  }, 'Stream.open_op options')
  if not (scope and scope._fibers_scope) then
    error('Stream.open_op scope must be a Scope', 3)
  end
  if type(handle) ~= 'table' or handle._fibers_host_handle ~= true then
    error('Stream.open_op expects a HostHandle', 3)
  end
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
  local name = opts.name or handle.name or 'host-stream'
  local reactor = Reactor.for_runtime(runtime)
  local stream = host_stream(name, {
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
  stream._reactor_live = #registrations
  for i = 1, #children do
    stream._lifetime:add_child(children[i])
  end
  return scope:admit_op(stream):and_then(function()
    return Op.named_all(registrations):map(function()
      return stream
    end)
  end)
end

function Stream.open_op(handle, opts)
  opts = opts or {}
  local scope = opts.scope or (Runtime.current_scope and Runtime.current_scope())
  if not scope then
    error('Stream.open_op requires opts.scope or a current Scope', 2)
  end
  return open_in_op(scope, handle, opts)
end

function Stream.merge_lines_op(streams, opts)
  local entries = {}
  for name, stream in pairs(streams or {}) do
    entries[#entries + 1] =
      { name, stream:read_line_op(opts):map(function(line, err)
        return name, line, err
      end) }
  end
  if #entries == 0 then
    return Op.never()
  end
  return Op.named_choice(entries):map(function(_, source, line, err)
    return source, line, err
  end)
end
function Stream.merge_lines(streams, opts)
  return perform(Stream.merge_lines_op(streams, opts))
end

return Stream
