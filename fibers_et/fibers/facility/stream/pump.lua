-- Host-pumped byte flows.
--
-- Pumps are ordinary Task bodies.  They perform host I/O only after readiness or
-- Flow state has committed, and they commit the result of host I/O back into
-- Flow state.  The default strategy starts separate read and write pump Tasks;
-- the host stream compound keeps that as a replaceable strategy detail.

local Runtime = require('fibers.kernel.runtime')
local Op = require('fibers.base.op')
local Task = require('fibers.base.task')
local Errors = require('fibers.facility.flow.errors')

local Pump = {}
Pump.Strategy = {}

local function backend_ready_op(backend, name)
  local f = backend and backend[name]
  if type(f) == 'function' then return f(backend) end
  return Op.always(true)
end

local function backend_call(backend, name, ...)
  local f = backend and backend[name]
  if type(f) == 'function' then return f(backend, ...) end
  return nil, 'unsupported_' .. tostring(name)
end

local function masked_perform(rt, op)
  return rt:perform(op, { masked = true })
end

function Pump.read(stream)
  local rt = Runtime.current()
  if not rt then error('stream read pump started without a runtime', 2) end
  local backend = stream.backend
  if backend and type(backend.attach_stream) == 'function' then backend:attach_stream(stream) end
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  local inlet = stream.read_flow:inlet()
  while true do
    local st = masked_perform(rt, stream.read_flow:state_op())
    if st.reader_open == false then
      backend_call(backend, 'shutdown_read', 'reader_closed')
      return
    end
    local st_cap = masked_perform(rt, stream.read_flow.capacity:state_op())
    local max, cap_err = st_cap and math.min(st_cap.free == math.huge and stream.read_chunk_size or st_cap.free, stream.read_chunk_size), nil
    if max == 0 then
      masked_perform(rt, stream.read_flow.capacity:changed_op(st_cap.version))
    else
      if not max then
        if cap_err == 'reader_closed' then backend_call(backend, 'shutdown_read', cap_err); return end
        masked_perform(rt, stream.read_flow.producer:fail_op(cap_err or Errors.READ_CAPACITY_ERROR))
        return
      end
      masked_perform(rt, backend_ready_op(backend, 'read_ready_op'))
      local bytes, err = backend_call(backend, 'read', max)
      if bytes and #bytes > 0 then
        masked_perform(rt, inlet:write_op(bytes))
      elseif err == 'would_block' or bytes == '' then
        -- Readiness is only a hint. Loop back to the readiness operation.
      elseif err == Errors.EOF then
        masked_perform(rt, inlet:shutdown_op(Errors.EOF))
        return
      else
        masked_perform(rt, stream.read_flow.producer:fail_op(err or Errors.READ_ERROR))
        return
      end
    end
  end
end

function Pump.write(stream)
  local rt = Runtime.current()
  if not rt then error('stream write pump started without a runtime', 2) end
  local backend = stream.backend
  if backend and type(backend.attach_stream) == 'function' then backend:attach_stream(stream) end
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  local outlet = stream.write_flow:outlet()
  while true do
    local claim_id, bytes_or_err = masked_perform(rt, outlet:claim_for_pump_op(stream.write_chunk_size))
    if not claim_id then
      if bytes_or_err == Errors.CLOSED_AND_DRAINED then
        backend_call(backend, 'shutdown_write', 'stream_closed')
        return
      end
      return
    end
    local bytes = bytes_or_err
    masked_perform(rt, backend_ready_op(backend, 'write_ready_op'))
    local n, err = backend_call(backend, 'write', bytes)
    if n and n > 0 then
      masked_perform(rt, outlet:ack_claim_op(claim_id, n))
    elseif err == 'would_block' or n == 0 then
      -- Keep the claim in-flight and wait for writability again.
    else
      masked_perform(rt, outlet:fail_write_op(err or Errors.WRITE_ERROR))
      return
    end
  end
end

function Pump.Strategy.split(stream, region, opts)
  opts = opts or {}
  local name = stream.name or 'host-stream'
  local read_task = Task.new(function() return Pump.read(stream) end, name .. ':read-pump', opts.frame)
  local write_task = Task.new(function() return Pump.write(stream) end, name .. ':write-pump', opts.frame)
  stream.read_task = read_task
  stream.write_task = write_task
  return Op.all({
    read_task:start_op(region),
    write_task:start_op(region),
  }):map(function() return stream end)
end

function Pump.start_op(stream, region, opts)
  opts = opts or {}
  local strategy = opts.pump_strategy or opts.strategy or stream.pump_strategy or 'split'
  local start
  if type(strategy) == 'function' then
    start = strategy
  elseif type(strategy) == 'table' and type(strategy.start_op) == 'function' then
    start = function(s, r, o) return strategy:start_op(s, r, o) end
  else
    start = Pump.Strategy[strategy]
  end
  if type(start) ~= 'function' then error('unknown stream pump strategy ' .. tostring(strategy), 2) end
  stream.pump_strategy = strategy
  return start(stream, region, opts)
end

return Pump
