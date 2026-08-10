-- Shared host <-> Flow byte transfer laws.
--
-- Host integrations differ in how they become runnable: readiness-driven
-- handles are serviced by Reactor, while completion-driven resources may run
-- these steps from a private driver fibre.  Once a Flow reservation or lease
-- has committed, however, the byte-custody protocol is identical.  This module
-- owns that protocol so sockets, files and future byte transports cannot drift.

local IOError = require('fibers.io.error')
local Errors = require('fibers.resource.flow.errors')
local Transfer = {}

local function masked_perform(runtime, option)
  return runtime:_perform_current(option, nil, true)
end

-- Complete one already-reserved input transfer.
--
-- read(capacity) -> bytes, err
--
-- Returns one of:
--   'progress', n
--   'would_block'
--   'eof'
--   'error', err
--
-- `empty_is_eof` is appropriate for regular files, whose provider contract
-- reports EOF as an empty successful read. Readiness handles must report EOF
-- explicitly so an empty successful read remains a backend protocol error.
function Transfer.settle_read(runtime, space, bytes, err, opts)
  opts = opts or {}
  if bytes ~= nil and type(bytes) ~= 'string' then
    masked_perform(runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return 'error', Errors.BACKEND_PROTOCOL_ERROR
  end
  if type(bytes) == 'string' and #bytes > space:capacity() then
    masked_perform(runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return 'error', Errors.BACKEND_PROTOCOL_ERROR
  end

  local eof = err == Errors.EOF or IOError.is_eof(err)
    or (opts.empty_is_eof == true and err == nil and bytes == '')
  if eof then
    if bytes and #bytes > 0 then
      local n, commit_err = masked_perform(runtime, space:commit_op(bytes))
      if not n then
        masked_perform(runtime, space:fail_op(commit_err or Errors.BACKEND_PROTOCOL_ERROR))
        return 'error', commit_err or Errors.BACKEND_PROTOCOL_ERROR
      end
    else
      masked_perform(runtime, space:release_op())
    end
    return 'eof'
  end

  if IOError.is_would_block(err) then
    if bytes ~= nil and bytes ~= '' then
      masked_perform(runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
      return 'error', Errors.BACKEND_PROTOCOL_ERROR
    end
    masked_perform(runtime, space:release_op())
    return 'would_block'
  end

  if err ~= nil then
    if bytes ~= nil and bytes ~= '' then
      masked_perform(runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
      return 'error', Errors.BACKEND_PROTOCOL_ERROR
    end
    masked_perform(runtime, space:fail_op(err))
    return 'error', err
  end

  if bytes == nil or bytes == '' then
    masked_perform(runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return 'error', Errors.BACKEND_PROTOCOL_ERROR
  end

  local n, commit_err = masked_perform(runtime, space:commit_op(bytes))
  if not n then
    masked_perform(runtime, space:fail_op(commit_err or Errors.BACKEND_PROTOCOL_ERROR))
    return 'error', commit_err or Errors.BACKEND_PROTOCOL_ERROR
  end
  return 'progress', n
end

function Transfer.read_reserved(runtime, space, read, opts)
  local bytes, err = read(space:capacity())
  return Transfer.settle_read(runtime, space, bytes, err, opts)
end

-- Complete one already-leased output transfer.
--
-- write(bytes) -> n, err
--
-- The lease remains active on `would_block`; on every successful partial write
-- it is acknowledged and therefore must be reacquired by the caller.
function Transfer.write_lease(runtime, lease, write)
  local n, err = write(lease:bytes())
  if n and n > 0 then
    if n > lease:length() then
      return 'error', Errors.BACKEND_PROTOCOL_ERROR
    end
    local ok, ack_err = masked_perform(runtime, lease:ack_op(n))
    if not ok then
      return 'error', ack_err or Errors.BACKEND_PROTOCOL_ERROR
    end
    return 'progress', n
  end
  if IOError.is_would_block(err) or n == 0 then
    return 'would_block'
  end
  return 'error', err or Errors.WRITE_ERROR
end

return Transfer
