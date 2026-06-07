-- Shared helpers for resource contract tests.

local M = {}

function M.fail(msg)
  error(msg, 2)
end

function M.assert_eq(actual, expected, msg)
  if actual ~= expected then
    M.fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

function M.assert_truthy(value, msg)
  if not value then M.fail(msg or 'expected truthy value') end
end

function M.assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    M.fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag) .. ' (' .. tostring(status and status.reason) .. ')')
  end
  return status.value
end

function M.assert_uncommitted_status(status, msg)
  local tag = status and status.tag
  if tag ~= 'absent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    M.fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

function M.transaction_tags(rt)
  local out = {}
  for i = 1, #(rt.published_consequences or {}) do
    local log = rt.published_consequences[i]
    for j = 1, #(log.transaction or {}) do
      local c = log.transaction[j]
      out[#out + 1] = c.tag or c.kind or tostring(c[1])
    end
    for j = 1, #(log.obligation or {}) do
      local c = log.obligation[j]
      local p = c.payload or {}
      out[#out + 1] = p.tag or p.kind or c.tag or c.kind or tostring(c[1])
    end
  end
  return table.concat(out, ',')
end

function M.obligation_entries(rt, kind)
  local out = {}
  for i = 1, #(rt.published_consequences or {}) do
    local log = rt.published_consequences[i]
    for j = 1, #(log.obligation or {}) do
      local c = log.obligation[j]
      if kind == nil or c.kind == kind or c.tag == kind then out[#out + 1] = c.payload or c end
    end
  end
  return out
end

return M
