-- Test-only access to Flow representation. No production inspection API.

local M = {}

local function state(value)
  if value and value._state then return value._state.value end
  return value
end

function M.data(value)
  local s = state(value)
  return s and s.rope and s.rope:peek(s.rope:length()) or ''
end

function M.queued(value)
  local s = state(value)
  return s and s.rope and s.rope:length() or 0
end

function M.leased_bytes(value)
  local s = state(value)
  return s and s.lease and #s.lease.bytes or 0
end

function M.first_lease_bytes(value)
  local s = state(value)
  return s and s.lease and s.lease.bytes or nil
end

function M.reserved(value)
  local s = state(value)
  return s and s.space and s.space.capacity or 0
end

function M.retained(value)
  return M.queued(value) + M.leased_bytes(value) + M.reserved(value)
end

function M.free(flow)
  if flow.capacity == math.huge then return math.huge end
  return flow.capacity - M.retained(flow)
end

function M.chunk_count(value)
  local s = state(value)
  local rope = s and s.rope or value
  if not rope or rope:length() == 0 then return 0 end
  local n, node = 0, rope.front
  while node do n, node = n + 1, node.next end
  node = rope.back
  while node do n, node = n + 1, node.next end
  return n
end

function M.search(rope, pattern)
  rope:find(pattern)
  return rope.searches[pattern]
end

return M
