-- Transactional streams.
--
-- A stream endpoint is an owned transactional byte boundary.  Reads consume
-- committed bytes; writes publish committed bytes; half-close and backpressure
-- are committed resource state.  Memory streams connect two ByteQueues directly.
-- Host-pumped streams add read/write pump Tasks around the same ByteQueue state.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Runtime = require('fibers.kernel.runtime')
local Pump = require('fibers.facility.stream.pump')
local Ownership = require('fibers.internal.ownership')
local Task = require('fibers.base.task')
local ByteQueue = require('fibers.facility.stream.byte_queue')

local Stream = {}
local Endpoint = {}
Endpoint.__index = Endpoint

local next_endpoint = 0

local function endpoint(opts)
  opts = opts or {}
  next_endpoint = next_endpoint + 1
  local name = opts.name or ('stream-' .. tostring(next_endpoint))
  local h = Ownership.handle(name, {
    kind = 'stream',
    mode = opts.mode or 'memory',
    incoming = opts.incoming,
    outgoing = opts.outgoing,
    backend = opts.backend,
    read_chunk_size = opts.read_chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or 4096,
    read_task = opts.read_task,
    write_task = opts.write_task,
    _fibers_stream = true,
    _fibers_kind_name = 'stream',
    _fibers_obligation_kind = 'stream',
  })
  return setmetatable(h, Endpoint)
end

function Stream.memory_pair(opts)
  opts = opts or {}
  local name = opts.name or 'memory-stream'
  local q_ab = ByteQueue.new { name = name .. ':a->b', capacity = opts.capacity }
  local q_ba = ByteQueue.new { name = name .. ':b->a', capacity = opts.capacity }
  return endpoint { name = name .. ':a', incoming = q_ba, outgoing = q_ab },
         endpoint { name = name .. ':b', incoming = q_ab, outgoing = q_ba }
end

function Stream.open_backend_op(region, backend, opts)
  opts = opts or {}
  if not region or type(region.admit_op) ~= 'function' then error('Stream.open_backend_op expects a Region', 2) end
  if type(backend) ~= 'table' then error('Stream.open_backend_op expects a backend table', 2) end
  local name = opts.name or backend.name or 'host-stream'
  local ep = endpoint {
    name = name,
    mode = 'host',
    backend = backend,
    incoming = ByteQueue.new { name = name .. ':in', capacity = opts.read_capacity or opts.capacity },
    outgoing = ByteQueue.new { name = name .. ':out', capacity = opts.write_capacity or opts.capacity },
    read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096,
  }
  local read_task = Task.new(function() return Pump.read(ep) end, name .. ':read-pump', opts.frame)
  local write_task = Task.new(function() return Pump.write(ep) end, name .. ':write-pump', opts.frame)
  ep.read_task = read_task
  ep.write_task = write_task
  if type(backend.attach_stream) == 'function' then backend:attach_stream(ep) end
  return Op.all({
    region:admit_op(ep),
    read_task:start_op(region),
    write_task:start_op(region),
  }):map(function() return ep end)
end

function Endpoint:read_some_op(max)
  return self.incoming:consume_some_op(max or 4096)
end

function Endpoint:read_exactly_op(n)
  return self.incoming:consume_exactly_op(n or 0)
end

function Endpoint:read_line_op(opts)
  return self.incoming:consume_line_op(opts or {})
end

function Endpoint:write_op(bytes)
  return self.outgoing:append_op(bytes or '')
end

function Endpoint:write_some_op(bytes)
  return self.outgoing:append_some_op(bytes or '')
end

function Endpoint:flush_op()
  if self.mode == 'host' then return self.outgoing:drained_op() end
  return Op.always(true)
end

function Endpoint:shutdown_write_op(reason)
  return self.outgoing:close_writer_op(reason)
end

function Endpoint:shutdown_read_op(reason)
  return self.incoming:close_reader_op(reason)
end

function Endpoint:close_op(reason)
  return Op.all({ self:shutdown_read_op(reason), self:shutdown_write_op(reason) }):map(function() return true end)
end

function Endpoint:state_op()
  return Op.all({ self.incoming:state_op(), self.outgoing:state_op() }):map(function(rows)
    return { stream = self, incoming = rows[1][1], outgoing = rows[2][1], mode = self.mode }
  end)
end

function Endpoint:closed_op()
  local function loop()
    return self:state_op():and_then(function(st)
      if st.incoming.reader_open == false and st.outgoing.writer_open == false and st.outgoing.drained then return Op.always(true) end
      return Op.choice(
        self.incoming:changed_op(st.incoming.version),
        self.outgoing:changed_op(st.outgoing.version)
      ):and_then(function() return loop() end)
    end)
  end
  return loop()
end

function Endpoint:exit_op()
  return self:closed_op()
end

function Endpoint:handoff_op(from, to)
  local from_region = from and from._fibers_lifetime and from:raw_region() or from
  local to_region = to and to._fibers_lifetime and to:raw_region() or to
  if not from_region or type(from_region.reassign_op) ~= 'function' then error('stream:handoff_op expects a source Lifetime or Region', 2) end
  if not to_region or to_region._fibers_kind ~= Region.Kind then error('stream:handoff_op expects a target Lifetime or Region', 2) end
  return from_region:reassign_op(self, to_region)
end

-- Friendly methods.  These deliberately sit above the Op layer and may perform
-- more than one transaction.
local function perform(op)
  local rt = Runtime.current()
  if not rt then error('stream convenience methods must run inside a fiber', 3) end
  local frame = Runtime._current_frame and Runtime._current_frame() or nil
  if frame and type(frame.perform) == 'function' then return frame:perform(op) end
  return rt:perform(op)
end

function Endpoint:read_some(max) return perform(self:read_some_op(max)) end
function Endpoint:read_exactly(n) return perform(self:read_exactly_op(n)) end
function Endpoint:read_line(opts) return perform(self:read_line_op(opts)) end
function Endpoint:flush() return perform(self:flush_op()) end
function Endpoint:close(reason) return perform(self:close_op(reason)) end

function Endpoint:write(bytes)
  bytes = bytes or ''
  local i = 1
  if #bytes == 0 then return true end
  while i <= #bytes do
    local n, err = perform(self:write_some_op(string.sub(bytes, i)))
    if not n then return nil, err end
    if n <= 0 then return nil, 'write_zero' end
    i = i + n
  end
  return true
end

Stream.endpoint = endpoint
Stream.Endpoint = Endpoint
Stream.ByteQueue = ByteQueue
Stream.backend = {
  Fake = require('fibers.facility.stream.backend.fake'),
  Readiness = require('fibers.facility.stream.backend.readiness'),
  Socket = require('fibers.facility.stream.backend.socket'),
}
return Stream
