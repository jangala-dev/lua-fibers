-- Test-only inspection of committed resource state. Production code must use Options.
local M = {}

function M.value(resource)
  return resource and resource._location and resource._location.value
end

function M.version(resource)
  return resource and resource._location and resource._location.version
end

function M.index_entries(index)
  return index and index._location and index._location.value or {}
end

function M.claim_holders(claim_set, subject)
  local location = claim_set and claim_set._space and claim_set._space.locations and claim_set._space.locations[subject]
  local value = location and location.value
  return value and next(value) ~= nil and value or nil
end

function M.event_queue_length(queue)
  local state = queue and queue._location and queue._location.value
  return state and state.count or 0
end

function M.lifecycle(value)
  local lifecycle = value and (value._lifecycle or value.lifecycle or value)
  local state = lifecycle and (lifecycle._location and lifecycle or lifecycle.state)
  return state and state._location and state._location.value or nil
end

function M.completion(completion)
  return completion and (completion._location and completion._location.value
    or completion.state and completion.state._location.value) or nil
end

function M.host_handle(value)
  local state = M.lifecycle(value)
  return state and state.handle or nil
end

return M
