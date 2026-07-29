-- Host protocol for external observations and retry interests.

-- Runtime-bound capability for externally mutating a transactional resource.

local Feed = {}
Feed.__index = Feed

function Feed.new(runtime, resource, apply, clear)
  if type(resource) ~= 'table' then
    error('Feed requires a resource', 2)
  end
  apply = apply or resource._fibers_external_deliver
  clear = clear or resource._fibers_external_clear
  if type(apply) ~= 'function' then
    error('resource does not support external delivery', 2)
  end
  return setmetatable({
    _fibers_external_feed = true,
    runtime = runtime,
    resource = resource,
    apply = apply,
    clear_apply = clear,
  }, Feed)
end

function Feed.for_resource(runtime, resource)
  if not runtime then
    return Feed.new(runtime, resource)
  end
  local cache = rawget(runtime, '_external_feeds')
  if not cache then
    cache = setmetatable({}, { __mode = 'kv' })
    runtime._external_feeds = cache
  end
  local feed = cache[resource]
  if not feed then
    feed = Feed.new(runtime, resource)
    cache[resource] = feed
  end
  return feed
end

function Feed.is_feed(value)
  return type(value) == 'table' and value._fibers_external_feed == true
end

function Feed:_deliver(...)
  return self.apply(self.resource, ...)
end

function Feed:_clear(...)
  if type(self.clear_apply) ~= 'function' then
    error('resource does not support external clear', 2)
  end
  return self.clear_apply(self.resource, ...)
end

function Feed:set(...)
  return self.runtime:deliver(self, ...)
end

function Feed:clear(...)
  return self.runtime:clear_external(self, ...)
end

function Feed:ready(mode, value)
  return self:set(mode, value == nil and true or value)
end

function Feed:readable(value)
  return self:set('read', value == nil and true or value)
end

function Feed:writable(value)
  return self:set('write', value == nil and true or value)
end

-- Host-actionable retry interests.
--
-- Interests are not evidence that retry is justified.  RetryProof frontiers
-- carry that evidence; an Interest merely tells the runtime or host how an
-- observed fact may change.

local Interest = {}
local next_id = 0

local function stable_resource_id(resource)
  if resource == nil then
    return nil
  end
  if type(resource) ~= 'table' then
    return tostring(resource)
  end
  if resource._fibers_id then
    return tostring(resource._fibers_id)
  end
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
  return type(x) == 'table' and x._fibers_interest == true
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
  if detail.resource_key == nil and detail.key ~= nil then
    detail.resource_key = detail.key
  end
  -- Compatibility for existing readiness host adapters.
  if detail.readiness_key == nil and detail.key ~= nil then
    detail.readiness_key = detail.key
  end
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
        poller = interest.poller,
      }
    else
      out[#out + 1] = interest
    end
  end
  return out
end

local External = { Feed = Feed, Interest = Interest }
return External
