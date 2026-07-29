local M = {}
function M.deliver(resource, ...)
  if type(resource) ~= 'table' or type(resource._fibers_external_deliver) ~= 'function' then
    error('resource does not support external delivery', 2)
  end
  return resource:_fibers_external_deliver(...)
end
function M.clear(resource, ...)
  if type(resource) ~= 'table' or type(resource._fibers_external_clear) ~= 'function' then
    error('resource does not support external clear', 2)
  end
  return resource:_fibers_external_clear(...)
end
return M
