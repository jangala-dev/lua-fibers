-- Host-actionable retry interests.
--
-- Interests are not evidence that retry is justified.  RetryProof frontiers
-- carry that evidence; an Interest merely tells the runtime or host how an
-- observed fact may change.

local Interest = {}
local next_id = 0

local function stable_resource_id(resource)
  if resource == nil then return nil end
  if type(resource) ~= 'table' then return tostring(resource) end
  if resource._fibers_id then return tostring(resource._fibers_id) end
  next_id = next_id + 1
  resource._fibers_interest_id = resource._fibers_interest_id or ('interest-resource-' .. tostring(next_id))
  return resource._fibers_interest_id
end

local function make(kind, key, fields)
  fields = fields or {}
  fields.kind = kind
  fields.key = key
  fields.id = tostring(kind) .. ':' .. tostring(key)
  fields._fibers_interest = true
  return fields
end

function Interest.is_interest(x)
  return type(x) == 'table' and (x._fibers_interest == true or x._fibers_wait == true)
end

function Interest.timer(deadline, resource, frontier)
  return make('timer', tostring(deadline), {
    deadline = deadline,
    resource = resource,
    frontier = frontier,
    primitive = 'timer',
  })
end

function Interest.external(resource, interest, detail)
  local rid = stable_resource_id(resource)
  local key = tostring(rid) .. ':' .. tostring(interest or 'ready')
  detail = detail or {}
  if detail.resource_key == nil and detail.key ~= nil then detail.resource_key = detail.key end
  -- Compatibility for existing readiness host adapters.
  if detail.readiness_key == nil and detail.key ~= nil then detail.readiness_key = detail.key end
  detail.resource = resource
  detail.interest = interest or 'ready'
  detail.external_kind = detail.external_kind or detail.kind or resource and resource.kind
  detail.primitive = 'external-resource'
  return make('external', key, detail)
end

function Interest.merge(list)
  local out, seen = {}, {}
  for i = 1, #(list or {}) do
    local interest = list[i]
    local id = Interest.is_interest(interest) and interest.id or tostring(interest)
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = interest
    end
  end
  return out
end

function Interest.summarise(list)
  local out = {}
  for i = 1, #(list or {}) do
    local interest = list[i]
    if Interest.is_interest(interest) then
      out[#out + 1] = {
        kind = interest.kind,
        key = interest.key,
        id = interest.id,
        deadline = interest.deadline,
        mode = interest.mode,
        interest = interest.interest,
        primitive = interest.primitive,
        resource = interest.resource,
        feed = interest.feed,
        resource_key = interest.resource_key,
        readiness_key = interest.readiness_key or interest.resource_key,
        external_kind = interest.external_kind,
      }
    else
      out[#out + 1] = interest
    end
  end
  return out
end


return Interest
