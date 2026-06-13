-- Host-pumped stream tasks.
--
-- Pumps are ordinary Task bodies.  They perform host I/O only after readiness or
-- ByteQueue state has committed, and they commit the result of host I/O back
-- into ByteQueue state.

local Runtime = require('fibers.kernel.runtime')
local Op = require('fibers.base.op')

local Pump = {}

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

function Pump.read(endpoint)
  local rt = Runtime.current()
  if not rt then error('stream read pump started without a runtime', 2) end
  local backend = endpoint.backend
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  while true do
    local st = masked_perform(rt, endpoint.incoming:state_op())
    if st.reader_open == false then
      backend_call(backend, 'shutdown_read', 'reader_closed')
      return
    end
    local max, cap_err = masked_perform(rt, endpoint.incoming:free_capacity_op(endpoint.read_chunk_size))
    if not max then
      if cap_err == 'reader_closed' then backend_call(backend, 'shutdown_read', cap_err); return end
      masked_perform(rt, endpoint.incoming:fail_read_op(cap_err or 'read_capacity_error'))
      return
    end
    masked_perform(rt, backend_ready_op(backend, 'read_ready_op'))
    local bytes, err = backend_call(backend, 'read', max)
    if bytes and #bytes > 0 then
      masked_perform(rt, endpoint.incoming:append_op(bytes))
    elseif err == 'would_block' or bytes == '' then
      -- Readiness is only a hint.  Loop back to the readiness operation.
    elseif err == 'eof' then
      masked_perform(rt, endpoint.incoming:close_writer_op('eof'))
      return
    else
      masked_perform(rt, endpoint.incoming:fail_read_op(err or 'read_error'))
      return
    end
  end
end

function Pump.write(endpoint)
  local rt = Runtime.current()
  if not rt then error('stream write pump started without a runtime', 2) end
  local backend = endpoint.backend
  if backend and type(backend.bind_runtime) == 'function' then backend:bind_runtime(rt) end
  while true do
    local claim_id, bytes_or_err = masked_perform(rt, endpoint.outgoing:claim_for_write_op(endpoint.write_chunk_size))
    if not claim_id then
      if bytes_or_err == 'closed_and_drained' then
        backend_call(backend, 'shutdown_write', 'stream_closed')
        return
      end
      return
    end
    local bytes = bytes_or_err
    masked_perform(rt, backend_ready_op(backend, 'write_ready_op'))
    local n, err = backend_call(backend, 'write', bytes)
    if n and n > 0 then
      masked_perform(rt, endpoint.outgoing:ack_claim_op(claim_id, n))
    elseif err == 'would_block' or n == 0 then
      -- Keep the claim in-flight and wait for writability again.
    else
      masked_perform(rt, endpoint.outgoing:fail_write_op(err or 'write_error'))
      return
    end
  end
end

return Pump
