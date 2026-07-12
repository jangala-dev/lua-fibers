-- Host-pumped byte flows.
--
-- Pumps are ordinary Task bodies.  They perform host I/O only after readiness or
-- precise Flow facts have committed.  Writes use Flow leases: the pump may call
-- the backend only on bytes that have been committed into a lease, then ack,
-- retain, or fail that lease according to the host result.

local Runtime = require('fibers.kernel.runtime')
local Op = require('fibers.atoms.op')
local Task = require('fibers.task')
local Settlement = require('fibers.internal.settlement')
local Errors = require('fibers.flow.errors')

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

local function named(name, operation)
  return operation:map(function(...) return name, ... end)
end

function Pump.read(stream)
  local rt = Runtime.current()
  if not rt then error('stream read pump started without a runtime', 2) end
  local backend = stream.backend
  if backend and type(backend.attach_stream) == 'function' then backend:attach_stream(stream) end
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  local flow = stream.read_flow
  local inlet = flow:inlet()
  while true do
    local cap_or_closed, value = masked_perform(rt,
      named('reader_closed', flow.output:closed_op()):or_else(
        named('capacity', flow.reservoir:capacity_some_op(stream.read_chunk_size))
      )
    )
    if cap_or_closed == 'reader_closed' then
      backend_call(backend, 'shutdown_read', 'reader_closed')
      return
    end
    local max = value

    local ready_or_closed = masked_perform(rt,
      named('reader_closed', flow.output:closed_op()):or_else(
        named('backend_ready', backend_ready_op(backend, 'read_ready_op'))
      )
    )
    if ready_or_closed == 'reader_closed' then
      backend_call(backend, 'shutdown_read', 'reader_closed')
      return
    end

    local bytes, err = backend_call(backend, 'read', max)
    if bytes and #bytes > 0 then
      local n, write_err = masked_perform(rt, inlet:write_op(bytes))
      if not n then
        if write_err == Errors.BROKEN_PIPE or write_err == Errors.CLOSED then
          backend_call(backend, 'shutdown_read', write_err)
          return
        end
        masked_perform(rt, flow.input:fail_op(write_err or Errors.READ_ERROR))
        return
      end
    elseif err == 'would_block' or bytes == '' then
      -- Readiness is only a hint. Loop back to the readiness option.
    elseif err == Errors.EOF then
      masked_perform(rt, inlet:shutdown_op(Errors.EOF))
      return
    else
      masked_perform(rt, flow.input:fail_op(err or Errors.READ_ERROR))
      return
    end
  end
end

function Pump.write(stream)
  local rt = Runtime.current()
  if not rt then error('stream write pump started without a runtime', 2) end
  local backend = stream.backend
  if backend and type(backend.attach_stream) == 'function' then backend:attach_stream(stream) end
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  local flow = stream.write_flow
  local outlet = flow:outlet()
  while true do
    local lease, lease_err = masked_perform(rt, outlet:lease_some_op(stream.write_chunk_size, stream))
    if not lease then
      if lease_err == Errors.CLOSED_AND_DRAINED then
        backend_call(backend, 'shutdown_write', 'stream_closed')
        return
      end
      return
    end
    local bytes = lease:bytes()
    local ready_or_failed = masked_perform(rt,
      named('write_failed', flow.output:error_op()):or_else(
        named('write_closed', flow.output:closed_op()):or_else(
          named('backend_ready', backend_ready_op(backend, 'write_ready_op'))
        )
      )
    )
    if ready_or_failed == 'write_failed' or ready_or_failed == 'write_closed' then return end
    local n, err = backend_call(backend, 'write', bytes)
    if n and n > 0 then
      local ok = masked_perform(rt, outlet:ack_lease_op(lease, n))
      if not ok then
        masked_perform(rt, outlet:fail_write_op(Errors.BACKEND_PROTOCOL_ERROR))
        return
      end
    elseif err == 'would_block' or n == 0 then
      -- Keep the lease in-flight and wait for writability again.
    else
      masked_perform(rt, outlet:fail_write_op(err or Errors.WRITE_ERROR))
      return
    end
  end
end

function Pump.Strategy.split_tasks(stream, opts)
  opts = opts or {}
  local name = stream.name or 'host-stream'
  local read_task = Task.new(function() return Pump.read(stream) end, name .. ':read-pump', opts.scope)
  local write_task = Task.new(function() return Pump.write(stream) end, name .. ':write-pump', opts.scope)
  stream.read_task = read_task
  stream.write_task = write_task
  return read_task, write_task
end

function Pump.Strategy.split(stream, region, opts)
  opts = opts or {}
  local read_task, write_task = Pump.Strategy.split_tasks(stream, opts)
  return Op.named_all({
    { 'read_task', read_task:start_op(region, Settlement.task_join_only(), { settle_name = 'task_join_only', role = 'read_pump' }) },
    { 'write_task', write_task:start_op(region, Settlement.task_join_only(), { settle_name = 'task_join_only', role = 'write_pump' }) },
  }):map(function() return stream end)
end

function Pump.create_tasks(stream, opts)
  opts = opts or {}
  local strategy = opts.pump_strategy or opts.strategy or stream.pump_strategy or 'split'
  if strategy ~= 'split' then return nil, 'Pump.create_tasks currently supports split strategy only' end
  stream.pump_strategy = strategy
  return Pump.Strategy.split_tasks(stream, opts)
end

function Pump.spawn_tasks_op(stream)
  local read_task, write_task = stream.read_task, stream.write_task
  if not read_task or not write_task then error('Pump.spawn_tasks_op requires prepared pump tasks', 2) end
  return Op.named_all({
    { 'read_task', read_task:spawn_effect_op() },
    { 'write_task', write_task:spawn_effect_op() },
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
