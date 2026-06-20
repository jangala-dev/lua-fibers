-- Test-only inspection helpers for flow reservoirs.
-- These are deliberately outside the library surface so the kernel/facilities do
-- not expose diagnostic methods in normal use.
local M = {}

function M.data(res)
  return res and res.rope and res.rope:tostring() or ''
end

function M.leased_bytes(res)
  local n = 0
  if not (res and res.leases) then return 0 end
  for _, lease in pairs(res.leases) do n = n + #(lease.bytes or '') end
  return n
end

function M.first_lease_bytes(res)
  if not (res and res.leases) then return nil end
  for _, lease in pairs(res.leases) do return lease.bytes or '' end
  return nil
end

return M
