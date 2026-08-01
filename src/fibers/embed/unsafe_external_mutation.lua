local External = require('fibers.embed.external')

local M = {}

function M.deliver(resource, ...)
  return External.unsafe_deliver(resource, ...)
end

function M.clear(resource, ...)
  return External.unsafe_clear(resource, ...)
end

return M
