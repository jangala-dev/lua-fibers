-- Bidirectional streams built from unidirectional byte flows.
--
-- Flow is the primitive byte abstraction. A Stream/Duplex is a compound over
-- two Flows. Host streams add a backend and pump obligations around those two
-- Flows.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Pump = require('fibers.facility.stream.pump')
local Claim = require('fibers.facility.stream.pump.claim')
local Ownership = require('fibers.internal.ownership')
local FlowFacility = require('fibers.facility.flow')
local Flow = FlowFacility.Flow

local Stream = {}
local Duplex = {}
Duplex.__index = Duplex
local HostStream = {}
HostStream.__index = HostStream

local next_duplex = 0
local next_host_stream = 0

local function region_of(x)
  return x and x._fibers_lifetime and x:raw_region() or x
end

local function expect_region(x, label)
  if not x or x._fibers_kind ~= Region.Kind then error(label .. ' expects a Region or Lifetime', 3) end
  return x
end

local function transfer_item_op(item, from, to, label)
  local from_region = expect_region(region_of(from), label)
  local to_region = expect_region(region_of(to), label)
  return from_region:reassign_op(item, to_region)
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
  local tx = Flow.new { name = name .. ':tx', capacity = opts.write_capacity or opts.capacity, read_chunk_size = opts.write_chunk_size, write_chunk_size = opts.write_chunk_size, pump_claim = Claim.new(name .. ':tx:claim') }
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

function Stream.open_backend_op(region, backend, opts)
  opts = opts or {}
  if not region or type(region.admit_op) ~= 'function' then error('Stream.open_backend_op expects a Region', 2) end
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
  return Op.named_all({
    { 'stream', region:admit_op(hs) },
    { 'reader', region:admit_op(hs:reader()) },
    { 'writer', region:admit_op(hs:writer()) },
    { 'pumps', Pump.start_op(hs, region, opts) },
  }):map(function() return hs end)
end

HostStream.reader = Duplex.reader
HostStream.writer = Duplex.writer
HostStream.read_flow_handle = Duplex.read_flow_handle
HostStream.write_flow_handle = Duplex.write_flow_handle
HostStream.inspect_op = Duplex.inspect_op
HostStream.shutdown_op = Duplex.shutdown_op
HostStream.closed_op = Duplex.closed_op
HostStream.exit_op = Duplex.exit_op
HostStream.transfer_op = Duplex.transfer_op
HostStream.transfer_reader_op = Duplex.transfer_reader_op
HostStream.transfer_writer_op = Duplex.transfer_writer_op

Stream.Duplex = Duplex
Stream.HostStream = HostStream
Stream.backend = {
  Fake = require('fibers.facility.stream.backend.fake'),
  Readiness = require('fibers.facility.stream.backend.readiness'),
  Socket = require('fibers.facility.stream.backend.socket'),
}
return Stream
