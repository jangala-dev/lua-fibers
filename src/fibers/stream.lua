-- Streams are capability-shaped compositions of unidirectional byte Flows.
--
-- A Stream adds no byte state of its own.  It pairs an optional Flow Outlet
-- with an optional Flow Inlet and composes their lifecycle operations. Host
-- handle integration lives in `fibers.io.stream` so memory Streams remain core.

local Op = require('fibers.op')
local Flow = require('fibers.resource.flow')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Stream, Duplex = {}, {}
Duplex.__index = Duplex

local function compose(opts)
  opts = opts or {}
  local stream = Label.attach(Label.identity(setmetatable({
    kind = opts.kind or 'stream',
    mode = opts.mode or 'composed',
    _reader = opts.reader,
    _writer = opts.writer,
  }, Duplex), 'stream'), opts.label)
  local children = {}
  if opts.reader then children[#children + 1] = opts.reader end
  if opts.writer then children[#children + 1] = opts.writer end
  Lifetime.define(stream, {
    label = opts.label,
    role = opts.kind or 'stream',
    closure = opts.closure or Closure.protocol({
      name = 'stream',
      finish_op = function(_ctx, record) return record.item:closed_op() end,
      finish_result = Closure.require_ok('stream closure failed'),
    }),
    children = children,
  })
  return stream
end

function Stream.compose(read_flow, write_flow, opts)
  opts = Contract.options(opts, { label = true, mode = true, kind = true }, 'Stream.compose options', 2)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'Stream.compose opts.label', 2) end
  if opts.mode ~= nil then Contract.non_empty_string(opts.mode, 'Stream.compose opts.mode', 2) end
  if opts.kind ~= nil then Contract.non_empty_string(opts.kind, 'Stream.compose opts.kind', 2) end
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
    label = opts.label,
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

local function forward_ops(side, names)
  for i = 1, #names do
    local name = names[i]
    Duplex[name .. '_op'] = function(self, ...)
      local ep = endpoint(self, side)
      return ep[name .. '_op'](ep, ...)
    end
  end
end

forward_ops('read', { 'read_some', 'read_exactly', 'read_until', 'read_line', 'read_all' })
forward_ops('write', { 'write_some', 'flush' })

local function write_bytes(...)
  local count = select('#', ...)
  if count == 0 then return '' end
  local parts = {}
  for i = 1, count do
    local part = select(i, ...)
    if type(part) ~= 'string' then error('stream write expects string arguments', 3) end
    parts[i] = part
  end
  return table.concat(parts)
end

function Duplex:write_op(...) return endpoint(self, 'write'):write_op(write_bytes(...)) end
function Duplex:write_all_op(...) return endpoint(self, 'write'):write_all_op(write_bytes(...)) end


local function flow_of(value)
  return value and value._flow
end


local function retire_direction(self, side, reason, policy, abort)
  local ep = side_endpoint(self, side)
  if not ep then
    return Op.always(true)
  end
  local request = abort and flow_of(ep):abort_op(reason) or ep:close_op(reason)
  local registration = self['_' .. side .. '_registration']
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
  return Op.together(
    self:shutdown_read_op(reason),
    abort_write and self:abort_write_op(reason) or self:shutdown_write_op(reason)
  ):map(function() return true end)
end

function Duplex:request_close_op(reason)
  return close_request(self, reason, false)
end

function Duplex:request_abort_op(reason)
  return close_request(self, reason, true)
end


function Duplex:closed_op()
  return Op.each({
    self._reader and self._reader:closed_op() or Op.always(true),
    self._writer and self._writer:closed_op() or Op.always(true),
    self._read_registration and self._read_registration:retired_op() or Op.always(true),
    self._write_registration and self._write_registration:retired_op() or Op.always(true),
  }):map(function()
    if self._close_error then return nil, self._close_error end
    return true
  end)
end

function Duplex:close(reason)
  local requested, request_err = perform(self:request_close_op(reason))
  if not requested then return nil, request_err end
  if self._writer then
    local flushed, flush_err = self._writer:flush()
    if not flushed then return nil, flush_err end
  end
  return perform(self:closed_op())
end

function Duplex:abort(reason)
  local requested, request_err = perform(self:request_abort_op(reason))
  if not requested then return nil, request_err end
  return perform(self:closed_op())
end


function Stream.memory_pair(opts)
  opts = Contract.options(opts, { label = true, capacity = true }, 'Stream.memory_pair options', 2)
  local label = opts.label or 'memory-flow'
  Contract.non_empty_string(label, 'Stream.memory_pair opts.label', 2)
  local ab = Flow.new(opts.capacity):label(label .. ':a->b')
  local ba = Flow.new(opts.capacity):label(label .. ':b->a')
  return Stream.compose(ba, ab, { label = label .. ':a', mode = 'memory' }),
    Stream.compose(ab, ba, { label = label .. ':b', mode = 'memory' })
end


function Stream.merge_lines_op(streams, opts)
  Contract.table(streams, 'Stream.merge_lines_op streams', 2)
  local entries = {}
  for name, stream in pairs(streams) do
    if type(stream) ~= 'table' or type(stream.read_line_op) ~= 'function' then
      error('Stream.merge_lines_op entries must be Streams', 2)
    end
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

Direct.install(Duplex, {
  'read_some', 'read_exactly', 'read_until', 'read_line', 'read_all',
  'write', 'write_all', 'write_some', 'flush',
  'shutdown_read', 'shutdown_write', 'abort_write', 'request_close', 'request_abort', 'closed',
})

return Stream
