-- Bidirectional streams built from unidirectional byte flows.
--
-- Flow is the primitive byte abstraction. A Stream/Duplex is a compound over
-- two Flows. Host streams add a backend and pump obligations around those two
-- Flows.

local Op = require('fibers.atoms.op')
local Region = require('fibers.atoms.region')
local Pump = require('fibers.stream.pump')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.atoms.region').Owned
local Settlement = require('fibers.internal.settlement')
local Flow = require('fibers.flow')

local Stream = {}
local Duplex = {}
Duplex.__index = Duplex
local HostStream = {}
HostStream.__index = HostStream

local next_duplex = 0
local next_host_stream = 0

local function region_of(x)
  if x and x._fibers_scope and type(x.raw_region) == 'function' then return x:raw_region() end
  if x and x._fibers_kind == Region.Kind then return x end
  return nil
end

local function expect_region(x, label)
  if not x or x._fibers_kind ~= Region.Kind then error(label .. ' expects a Region or Scope', 3) end
  return x
end

local function transfer_item_op(item, from, to, label)
  local from_region = expect_region(region_of(from), label)
  local to_region = expect_region(region_of(to), label)
  return from_region:move_op(item, to_region)
end

local function duplex(opts)
  opts = opts or {}
  next_duplex = next_duplex + 1
  local name = opts.name or ('duplex-' .. tostring(next_duplex))
  local d = Ownership.handle(name, {
    kind = opts.kind or 'duplex_stream',
    mode = opts.mode or 'memory',
    read_flow = opts.read_flow,
    write_flow = opts.write_flow,
    backend = opts.backend,
    pump_strategy = opts.pump_strategy,
    read_task = nil,
    write_task = nil,
    pump_task = nil,
    _fibers_stream = true,
    _fibers_duplex_stream = true,
    _fibers_kind_name = opts.kind or 'duplex_stream',
    _fibers_obligation_kind = opts.kind or 'duplex_stream',
    settle = opts.settle or Settlement.stream(),
    settle_name = opts.settle_name or 'stream',
  })
  setmetatable(d, opts.metatable or Duplex)
  return d
end

function Duplex:reader() return self.read_flow:outlet() end
function Duplex:writer() return self.write_flow:inlet() end
function Duplex:read_flow_handle() return self.read_flow end
function Duplex:write_flow_handle() return self.write_flow end

function Duplex:inspect_op()
  return Op.named_all({
    { 'read', self.read_flow:inspect_op() },
    { 'write', self.write_flow:inspect_op() },
  }):map(function(parts)
    return { stream = self, read = parts.read, write = parts.write, mode = self.mode }
  end)
end

function Duplex:close_op(reason) return self:shutdown_op(reason) end

function Duplex:shutdown_op(reason)
  return Op.named_all({
    { 'reader', self:reader():shutdown_op(reason) },
    { 'writer', self:writer():shutdown_op(reason) },
  }):map(function() return true end)
end

function Duplex:closed_op()
  return Op.named_all({
    { 'read', self.read_flow:closed_op() },
    { 'write', self.write_flow:closed_op() },
  }):map(function() return true end)
end

function Duplex:exit_op() return self:closed_op() end
function Duplex:transfer_op(from, to) return transfer_item_op(self, from, to, 'stream:transfer_op') end
function Duplex:transfer_reader_op(from, to) return self:reader():transfer_op(from, to) end
function Duplex:transfer_writer_op(from, to) return self:writer():transfer_op(from, to) end

local function host_stream(opts)
  opts = opts or {}
  next_host_stream = next_host_stream + 1
  local name = opts.name or ('host-stream-' .. tostring(next_host_stream))
  local rx = Flow.new { name = name .. ':rx', capacity = opts.read_capacity or opts.capacity, read_chunk_size = opts.read_chunk_size, write_chunk_size = opts.read_chunk_size }
  local tx = Flow.new { name = name .. ':tx', capacity = opts.write_capacity or opts.capacity, read_chunk_size = opts.write_chunk_size, write_chunk_size = opts.write_chunk_size }
  local h = duplex {
    name = name,
    kind = 'host_stream',
    mode = 'host',
    read_flow = rx,
    write_flow = tx,
    backend = opts.backend,
    pump_strategy = opts.pump_strategy,
    metatable = HostStream,
  }
  h.read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096
  h.write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096
  h._fibers_host_stream = true
  return h
end

function Stream.memory_pair(opts)
  opts = opts or {}
  local name = opts.name or 'memory-flow'
  local flow_ab = Flow.new { name = name .. ':a->b', capacity = opts.capacity }
  local flow_ba = Flow.new { name = name .. ':b->a', capacity = opts.capacity }
  local a = duplex { name = name .. ':a', read_flow = flow_ba, write_flow = flow_ab, mode = 'memory' }
  local b = duplex { name = name .. ':b', read_flow = flow_ab, write_flow = flow_ba, mode = 'memory' }
  return a, b
end

function Stream.open_backend_in_op(owner, backend, opts)
  opts = opts or {}
  local region = region_of(owner)
  if not region or type(region.admit_op) ~= 'function' then error('Stream.open_backend_in_op expects a Scope or Region owner', 2) end
  if type(backend) ~= 'table' then error('Stream.open_backend_op expects a backend table', 2) end
  local name = opts.name or backend.name or 'host-stream'
  local hs = host_stream {
    name = name,
    backend = backend,
    read_capacity = opts.read_capacity or opts.capacity,
    write_capacity = opts.write_capacity or opts.capacity,
    read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096,
    pump_strategy = opts.pump_strategy or opts.strategy or 'split',
  }
  local strategy = opts.pump_strategy or opts.strategy or hs.pump_strategy or 'split'
  local owned_children = {
    Owned.item(hs.read_flow, hs.read_flow._fibers_settle or Settlement.flow(), { role = 'read_flow', settle_name = 'flow' }),
    Owned.item(hs.write_flow, hs.write_flow._fibers_settle or Settlement.flow(), { role = 'write_flow', settle_name = 'flow' }),
    Owned.inert(hs:reader(), { role = 'reader' }),
    Owned.inert(hs:writer(), { role = 'writer' }),
  }
  local start_op
  if strategy == 'split' or strategy == nil then
    local pump_opts = opts
    if owner and owner._fibers_scope then
      pump_opts = {}
      for k, v in pairs(opts) do pump_opts[k] = v end
      pump_opts.scope = pump_opts.scope or owner
    end
    local read_task, write_task = Pump.create_tasks(hs, pump_opts)
    owned_children[#owned_children + 1] = read_task:owned(Settlement.task_join_only(), { role = 'read_pump', settle_name = 'task_join_only' })
    owned_children[#owned_children + 1] = write_task:owned(Settlement.task_join_only(), { role = 'write_pump', settle_name = 'task_join_only' })
    start_op = Pump.spawn_tasks_op(hs)
  else
    start_op = Pump.start_op(hs, region, opts)
  end
  local owned = Owned.tree(hs, hs._fibers_settle or Settlement.stream(), owned_children, { role = 'stream', settle_name = 'stream' })
  local admit_op = owner and owner._fibers_scope and type(owner.admit_op) == 'function' and owner:admit_op(owned) or region:admit_op(owned)
  return admit_op:and_then(function()
    return start_op:map(function() return hs end)
  end)
end

function Stream.open_backend_op(backend, opts)
  -- Safe form: Stream.open_backend_op(backend, { owner = scope? }).  A missing
  -- owner uses the current Scope.  Low-level owner-first code should use
  -- Stream.open_backend_in_op(owner, backend, opts) so structural acquisition is
  -- explicit rather than accidental.
  opts = opts or {}
  if region_of(backend) then error('Stream.open_backend_op no longer accepts owner first; use Stream.open_backend_in_op(owner, backend, opts)', 2) end
  local Runtime = require('fibers.kernel.runtime')
  local scope = opts.owner or (Runtime.current_scope and Runtime.current_scope())
  if not scope then error('Stream.open_backend_op requires a current Scope or opts.owner', 2) end
  return Stream.open_backend_in_op(scope, backend, opts)
end

function Stream.open_handle_in_op(owner, handle, opts)
  opts = opts or {}
  local Backend = require('fibers.stream.backend.handle')
  return Stream.open_backend_in_op(owner, Backend.new(handle, opts), opts)
end

function Stream.open_handle_op(handle, opts)
  opts = opts or {}
  local Backend = require('fibers.stream.backend.handle')
  if region_of(handle) then error('Stream.open_handle_op no longer accepts owner first; use Stream.open_handle_in_op(owner, handle, opts)', 2) end
  return Stream.open_backend_op(Backend.new(handle, opts), opts)
end

HostStream.reader = Duplex.reader
HostStream.writer = Duplex.writer
HostStream.read_flow_handle = Duplex.read_flow_handle
HostStream.write_flow_handle = Duplex.write_flow_handle
HostStream.inspect_op = Duplex.inspect_op
HostStream.close_op = Duplex.close_op
HostStream.shutdown_op = Duplex.shutdown_op
HostStream.closed_op = Duplex.closed_op
HostStream.exit_op = Duplex.exit_op
HostStream.transfer_op = Duplex.transfer_op
HostStream.transfer_reader_op = Duplex.transfer_reader_op
HostStream.transfer_writer_op = Duplex.transfer_writer_op

Stream.Duplex = Duplex
Stream.HostStream = HostStream
Stream.backend = {
  Fake = require('fibers.stream.backend.fake'),
  Readiness = require('fibers.stream.backend.readiness'),
  Socket = require('fibers.stream.backend.socket'),
  Handle = require('fibers.stream.backend.handle'),
}
return Stream
