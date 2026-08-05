local Proof = require('fibers.internal.proof')

-- Authorised host delivery into versioned managed locations.

local External = {}
local Feed = {}
Feed.__index = Feed

local function descriptor(resource)
  return type(resource) == 'table' and rawget(resource, '_fibers_external_feed_spec') or nil
end

function External.attach(resource, location, deliver, clear)
  if type(resource) ~= 'table' then error('external feed requires a resource', 2) end
  if type(location) ~= 'table' then error('external feed requires a managed location', 2) end
  if type(deliver) ~= 'function' then error('external feed requires a delivery function', 2) end
  resource._fibers_external_feed_spec = {
    location = location,
    deliver = deliver,
    clear = clear,
  }
  return resource
end

local function publish(spec, resource, fn, ...)
  if type(fn) ~= 'function' then error('resource does not support this external mutation', 3) end
  local value = fn(spec.location.value, resource, ...)
  rawset(spec.location, 'value', value)
  rawset(spec.location, 'version', (spec.location.version or 0) + 1)
  return value
end

function Feed.new(runtime, resource)
  local spec = descriptor(resource)
  if not spec then error('resource does not support external delivery', 2) end
  return setmetatable({
    _fibers_external_feed = true,
    runtime = runtime,
    resource = resource,
    spec = spec,
  }, Feed)
end

function Feed.for_resource(runtime, resource)
  if not runtime then return Feed.new(runtime, resource) end
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
  return publish(self.spec, self.resource, self.spec.deliver, ...)
end

function Feed:_clear(...)
  return publish(self.spec, self.resource, self.spec.clear, ...)
end

function Feed:set(...)
  return External.deliver(self.runtime, self, ...)
end

function Feed:clear(...)
  return External.clear(self.runtime, self, ...)
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

function External.unsafe_deliver(resource, ...)
  local spec = descriptor(resource)
  if not spec then error('resource does not support external delivery', 2) end
  return publish(spec, resource, spec.deliver, ...)
end

function External.unsafe_clear(resource, ...)
  local spec = descriptor(resource)
  if not spec or type(spec.clear) ~= 'function' then
    error('resource does not support external clear', 2)
  end
  return publish(spec, resource, spec.clear, ...)
end

-- Host-actionable retry interests.
--
-- Interests are not evidence that retry is justified.  RetryProof frontiers
-- carry that evidence; an Interest merely tells the runtime or host how an
-- observed fact may change.

local Interest = {}

local INTEREST_DETAIL = {
  external_kind = true, readiness_key = true, mode = true, feed = true, poller = true,
}
local DRIVE_OPTIONS = { host = true, run = true, max_iterations = true, host_options = true }

local function validate_keys(value, allowed, label, level)
  if value ~= nil and type(value) ~= 'table' then error(label .. ' must be a table', level or 3) end
  for key in pairs(value or {}) do
    if not allowed[key] then error(label .. ' does not accept ' .. tostring(key), level or 3) end
  end
end
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
  validate_keys(detail, INTEREST_DETAIL, 'external interest detail', 2)
  detail.resource = resource
  detail.interest = interest or 'ready'
  detail.external_kind = detail.external_kind or resource and resource.kind
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
        readiness_key = interest.readiness_key,
        external_kind = interest.external_kind,
        poller = interest.poller,
      }
    else
      out[#out + 1] = interest
    end
  end
  return out
end

External.Feed, External.Interest = Feed, Interest


local function optional(module_name, feature)
  local ok, module = pcall(require, module_name)
  if ok then return module end
  error((feature or module_name) .. ' requires optional package module ' .. module_name .. ': ' .. tostring(module), 3)
end

function External.external_feed(runtime, resource)
  return Feed.for_resource(runtime, resource)
end

local function mutate(runtime, feed, action, expectation, dirty_reason, apply, ...)
  runtime:_check_not_failed(3)
  runtime:_require_driver_call(action, 3)
  if not Feed.is_feed(feed) then error(expectation, 3) end
  if feed.runtime ~= runtime then error('external feed belongs to another runtime', 3) end
  apply(feed, ...)
  local engine = runtime.engine
  engine.epoch = engine.epoch + 1
  Proof.touch_resource(engine, feed.resource, dirty_reason)
  return feed.resource
end

function External.deliver(runtime, feed, ...)
  return mutate(runtime, feed, 'external delivery', 'External.deliver expects an ExternalFeed',
    'external-delivery', Feed._deliver, ...)
end

function External.clear(runtime, feed, ...)
  return mutate(runtime, feed, 'clear external resource',
    'External.clear expects an ExternalFeed', 'external-clear', Feed._clear, ...)
end

function External.signal(runtime)
  local resource = require('fibers.resource.signal').new()
  return resource, Feed.for_resource(runtime, resource)
end

function External.events(runtime)
  local resource = require('fibers.resource.event_queue').new()
  return resource, Feed.for_resource(runtime, resource)
end

function External.readiness(runtime, key)
  local resource = optional('fibers.io.readiness', 'External.readiness').new(key)
  return resource, Feed.for_resource(runtime, resource)
end

function External.drive(runtime, opts)
  opts = opts or {}
  validate_keys(opts, DRIVE_OPTIONS, 'External.drive options', 2)
  local host = opts.host or runtime.host
  local run_opts = opts.run
  local max_iterations = opts.max_iterations
  local iterations, last_found = 0, nil
  while true do
    iterations = iterations + 1
    if max_iterations and iterations > max_iterations then
      return { tag = 'pending', reason = 'runtime drive iteration budget exhausted' }
    end
    local status = runtime:run(run_opts)
    if status and status.tag == 'found' then
      last_found = status
    elseif status and status.tag == 'pending' then
      local interests = status.interests or {}
      if not host or type(host.block) ~= 'function' then error('runtime host must implement block', 2) end
      local progressed, reason = host:block(runtime, interests, status, opts.host_options or {})
      if not progressed then
        status.host_reason = reason
        status.reason = status.reason or reason
        status.interests = interests
        return status
      end
    elseif status and (status.tag == 'idle' or status.tag == 'quiescent') then
      return last_found or status
    else
      return status
    end
  end
end

return External
