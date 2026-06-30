-- Generic ownership claim values.
--
-- A Region claim is an authority value produced by Region:claim_op.  It marks a
-- live owned subtree as claimed for a purpose.  The holder of the claim may then
-- run an ordinary settlement protocol and finally settle the claim.

local Claim = {}

local next_claim = 0

function Claim.new(region, root, records, purpose)
  if type(records) ~= 'table' then error('Claim.new requires records table', 2) end
  next_claim = next_claim + 1
  local id = 'claim-' .. tostring(next_claim)
  return {
    _fibers_claim = true,
    _fibers_value = true,
    id = id,
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

return Claim
