-- Streams are capability-shaped compositions of unidirectional byte Flows.
--
-- A Stream adds no byte state of its own.  It pairs an optional Flow Outlet
-- with an optional Flow Inlet and composes their lifecycle operations. Host
-- handle integration lives in `fibers.io.stream` so memory Streams remain core.

local Op = require('fibers.op')
local Flow = require('fibers.resource.flow')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local Runtime = require('fibers.runtime')
local Direct = require('fibers.internal.direct')

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

function Duplex:read_some_op(n)
  return endpoint(self, 'read'):read_some_op(n)
end

function Duplex:read_exactly_op(n)
  return endpoint(self, 'read'):read_exactly_op(n)
end

function Duplex:read_until_op(separator, opts)
  return endpoint(self, 'read'):read_until_op(separator, opts)
end

function Duplex:read_line_op(opts)
  return endpoint(self, 'read'):read_line_op(opts)
end

function Duplex:read_all_op(opts)
  return endpoint(self, 'read'):read_all_op(opts)
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
    request = Op.together({ request, registration:retire_op(reason, policy) }):map(function()
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
  return #operations == 0 and Op.always(true) or Op.together(operations):map(function()
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
  return Op.each(operations):map(function()
    if self._close_error then
      return nil, self._close_error
    end
    return true
  end)
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

function Stream.merge_lines_op(streams, opts)
  local entries = {}
  for name, stream in pairs(streams or {}) do
    entries[name] = stream:read_line_op(opts):map(function(line, err)
      return name, line, err
    end)
  end
  if next(entries) == nil then
    return Op.never()
  end
  return Op.named_choice(entries):map(function(_, source, line, err)
    return source, line, err
  end)
end
Direct.install_static(Stream, { 'merge_lines' })

Direct.install(
  Duplex,
  {
    'read_some',
    'read_exactly',
    'read_until',
    'read_line',
    'read_all',
    'read',
    'write',
    'write_some',
    'flush',
    'shutdown_read',
    'shutdown_write',
    'abort_write',
    'close',
    'abort',
    'closed',
  }
)

return Stream
