local Ownership = {}
local next_handle = 0
local Kind = { name = 'ownership' }

local function no_settlement()
  return function()
    return require('fibers.op').always(true)
  end
end

function Ownership.handle(name, fields)
  next_handle = next_handle + 1
  local id = 'owned-' .. tostring(next_handle)
  local h = fields or {}
  h.name = name or h.name or id
  h.owner = h.owner
  h.owner_version = h.owner_version or 0
  h._fibers_id = h._fibers_id or id
  h._fibers_kind = Kind
  h._fibers_obligation_kind = h._fibers_obligation_kind or h.kind
  h._fibers_settle = h._fibers_settle or h.settle or no_settlement()
  h._fibers_settle_name = h._fibers_settle_name or h.settle_name or 'none'
  return h
end

Ownership.Kind = Kind
return Ownership
