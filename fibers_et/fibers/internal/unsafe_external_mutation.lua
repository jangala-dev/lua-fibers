-- Trusted direct mutation inside the runtime boundary. Ordinary external code must use ExternalFeed.

local UnsafeExternalMutation = {}

function UnsafeExternalMutation.deliver(resource, ...)
  local apply = resource and resource._fibers_external_deliver
  if type(apply) ~= 'function' then
    error('resource does not support external delivery', 2)
  end
  apply(resource, ...)
  return resource
end

function UnsafeExternalMutation.clear(resource, ...)
  local apply = resource and resource._fibers_external_clear
  if type(apply) ~= 'function' then
    error('resource does not support external clear', 2)
  end
  apply(resource, ...)
  return resource
end

return UnsafeExternalMutation
