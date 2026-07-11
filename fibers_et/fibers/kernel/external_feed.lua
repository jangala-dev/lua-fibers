-- Runtime-bound capability for externally mutating a transactional resource.

local ExternalFeed = {}
ExternalFeed.__index = ExternalFeed

function ExternalFeed.new(runtime, resource, apply, clear)
  if type(resource) ~= 'table' then error('ExternalFeed requires a resource', 2) end
  apply = apply or resource._fibers_external_deliver
  clear = clear or resource._fibers_external_clear
  if type(apply) ~= 'function' then error('resource does not support external delivery', 2) end
  return setmetatable({
    _fibers_external_feed = true,
    runtime = runtime,
    resource = resource,
    apply = apply,
    clear_apply = clear,
  }, ExternalFeed)
end

function ExternalFeed.for_resource(runtime, resource)
  if not runtime then return ExternalFeed.new(runtime, resource) end
  local cache = rawget(runtime, '_external_feeds')
  if not cache then
    cache = setmetatable({}, { __mode = 'k' })
    runtime._external_feeds = cache
  end
  local feed = cache[resource]
  if not feed then
    feed = ExternalFeed.new(runtime, resource)
    cache[resource] = feed
  end
  return feed
end

function ExternalFeed.is_feed(value)
  return type(value) == 'table' and value._fibers_external_feed == true
end

function ExternalFeed:_deliver(...)
  return self.apply(self.resource, ...)
end

function ExternalFeed:_clear(...)
  if type(self.clear_apply) ~= 'function' then error('resource does not support external clear', 2) end
  return self.clear_apply(self.resource, ...)
end

function ExternalFeed:deliver(...)
  return self.runtime:deliver(self, ...)
end

function ExternalFeed:clear(...)
  return self.runtime:clear_external(self, ...)
end

ExternalFeed.set = ExternalFeed.deliver
ExternalFeed.push = ExternalFeed.deliver

function ExternalFeed:ready(mode, value)
  return self:deliver(mode, value == nil and true or value)
end

function ExternalFeed:readable(value)
  return self:deliver('read', value == nil and true or value)
end

function ExternalFeed:writable(value)
  return self:deliver('write', value == nil and true or value)
end

return ExternalFeed
