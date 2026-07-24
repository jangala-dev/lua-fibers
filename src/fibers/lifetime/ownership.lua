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

local Claim = {}
local next_claim = 0

function Claim.new(region, root, records, purpose)
  next_claim = next_claim + 1
  return {
    _fibers_claim = true,
    _fibers_value = true,
    id = 'claim-' .. tostring(next_claim),
    region = region,
    root = root,
    records = records,
    purpose = purpose,
    reason = type(purpose) == 'table' and purpose.reason or nil,
  }
end

function Claim.is(x)
  return type(x) == 'table' and x._fibers_claim == true
end

Ownership.Claim = Claim
return Ownership
