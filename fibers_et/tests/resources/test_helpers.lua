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
  return table.concat(rt._test_tags or {}, ',')
end

function M.obligation_entries(_rt, _kind)
  return {}
end

function M.tagging_host(rt_opts)
  rt_opts = rt_opts or {}
  local tags = {}
  local host = rt_opts.host or {}
  local previous = host.test_tag
  host.test_tag = function(tag, payload)
    tags[#tags + 1] = tag
    if previous then return previous(tag, payload) end
  end
  rt_opts.host = host
  return rt_opts, tags
end

return M
