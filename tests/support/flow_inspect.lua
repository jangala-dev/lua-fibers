-- Test-only inspection helpers for Flow state.
-- These are deliberately outside the library surface so the kernel/facilities do
-- not expose diagnostic methods in normal use.
local M = {}

function M.data(res)
  local state = res and res.state and res.state.value or res
  return state and state.rope and state.rope:tostring() or ''
end

function M.leased_bytes(res)
  local n = 0
  local state = res and res.state and res.state.value or res
  if not state then
    return 0
  end
  if state.lease_bytes ~= nil then
    return #(state.lease_bytes or '')
  end
  if not state.leases then
    return 0
  end
  for _, lease in pairs(state.leases) do
    n = n + #(lease.bytes or '')
  end
  return n
end

function M.first_lease_bytes(res)
  local state = res and res.state and res.state.value or res
  if not state then
    return nil
  end
  if state.lease_bytes ~= nil then
    return state.lease_bytes or ''
  end
  if not state.leases then
    return nil
  end
  for _, lease in pairs(state.leases) do
    return lease.bytes or ''
  end
  return nil
end

return M
