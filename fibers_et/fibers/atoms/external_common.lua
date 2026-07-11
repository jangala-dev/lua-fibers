-- Shared construction and interest helpers for externally observed resources.

local ExternalFeed = require('fibers.kernel.external_feed')
local Interest = require('fibers.kernel.interest')

local Common = {}
local next_id = 0

function Common.new(kind, class, resource_kind, fields, validity)
  next_id = next_id + 1
  fields = fields or {}
  fields.kind = kind
  fields.name = fields.name or (kind .. '-' .. tostring(next_id))
  fields._fibers_id = 'source-' .. tostring(next_id)
  fields._fibers_kind = resource_kind
  fields._validity = validity(fields.name)
  return setmetatable(fields, class)
end

function Common.interest(ctx, resource, interest, detail)
  detail = detail or {}
  if ctx and ctx.rt then detail.feed = ExternalFeed.for_resource(ctx.rt, resource) end
  return Interest.external(resource, interest, detail)
end

function Common.normalise_readiness_mode(mode, level)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then
    error('readiness mode must be read or write', level or 3)
  end
  return mode
end

return Common
