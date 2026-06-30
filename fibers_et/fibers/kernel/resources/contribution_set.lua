-- Once-only proof contributions.
--
-- A premise resolver may produce a proposal that belongs to the solution as a
-- whole rather than to any one resumed premise.  The same contribution id may
-- be carried by several speculative task environments; environment merges
-- deduplicate by id and the contribution's proposal participates in final
-- resource preparation exactly once.

local Proposal = require('fibers.kernel.resources.proposal')

local ContributionSet = {}
ContributionSet.__index = ContributionSet

function ContributionSet.empty()
  return setmetatable({ entries = {}, order = {} }, ContributionSet)
end

function ContributionSet.is_set(x)
  return type(x) == 'table' and getmetatable(x) == ContributionSet
end

function ContributionSet:copy()
  local out = ContributionSet.empty()
  for i = 1, #self.order do
    local id = self.order[i]
    out.order[i] = id
    out.entries[id] = Proposal.clone(self.entries[id])
  end
  return out
end

function ContributionSet:is_empty()
  return #self.order == 0
end

function ContributionSet:add(id, proposal)
  if id == nil then
    return nil, { kind = 'invalid_contribution', message = 'proof contribution requires an id' }
  end
  if type(proposal) ~= 'table' then
    return nil, { kind = 'invalid_contribution', message = 'proof contribution requires a proposal' }
  end

  local k = tostring(id)
  if self.entries[k] then return self end

  self.entries[k] = Proposal.clone(proposal)
  self.order[#self.order + 1] = k
  return self
end

function ContributionSet:merge(other)
  if not other or other:is_empty() then return self end
  for i = 1, #other.order do
    local id = other.order[i]
    local ok, err = self:add(id, other.entries[id])
    if not ok then return nil, err end
  end
  return self
end

function ContributionSet:items()
  local out = {}
  for i = 1, #self.order do
    local id = self.order[i]
    out[#out + 1] = { id = id, proposal = self.entries[id] }
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

return ContributionSet
