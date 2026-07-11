-- Proof-carrying retry.
--
-- The proof table itself stores debug observations. Explicit frontiers and host
-- interests are separate lazy lists. An observation's frontier is deliberately
-- not duplicated into the explicit frontier list: consumers validate both.

local RetryProof = {}
local methods = {}
local EMPTY = {}

local function owned_list(self, field)
  local list = rawget(self, field)
  if list == nil or list == EMPTY then
    list = {}
    rawset(self, field, list)
  end
  return list
end

local function append_unique(list, value, key)
  if value == nil then return end
  key = key or value
  for i = 1, #list do
    local v = list[i]
    local vk = (type(v) == 'table' and (v.id or v.key)) or v
    if vk == key then return end
  end
  list[#list + 1] = value
end

function RetryProof.new(items, interests, opts)
  opts = opts or {}
  local self = setmetatable({
    frontiers = EMPTY,
    interests = EMPTY,
    permanent = opts.permanent == true,
    reason = opts.reason,
  }, RetryProof)
  if items then methods.merge(self, items) end
  for i = 1, #(interests or EMPTY) do methods.add_interest(self, interests[i]) end
  return self
end

function RetryProof.permanent(reason)
  return RetryProof.new(nil, nil, { permanent = true, reason = reason or 'permanent' })
end

function RetryProof.is_retry_proof(x)
  return type(x) == 'table' and getmetatable(x) == RetryProof
end

function methods:add(obs)
  if obs then self[#self + 1] = obs end
  return self
end

function methods:observe(frontier)
  append_unique(owned_list(self, 'frontiers'), frontier, frontier)
  return self
end

function methods:add_interest(interest)
  local key = interest and (interest.id or interest.key or interest)
  append_unique(owned_list(self, 'interests'), interest, key)
  return self
end

function methods:merge(other)
  if not other then return self end
  if RetryProof.is_retry_proof(other) then
    for i = 1, #other do methods.add(self, other[i]) end
    for i = 1, #other.frontiers do methods.observe(self, other.frontiers[i]) end
    for i = 1, #other.interests do methods.add_interest(self, other.interests[i]) end
    if other.permanent then self.permanent = true end
    self.reason = self.reason or other.reason
    return self
  end
  if type(other) ~= 'table' then error('RetryProof:merge expected proof/table, got ' .. type(other), 2) end
  for i = 1, #other do methods.add(self, other[i]) end
  return self
end

function methods:merge_evidence(other)
  if not other then return self end
  if RetryProof.is_retry_proof(other) then
    for i = 1, #other do methods.add(self, other[i]) end
    for i = 1, #other.frontiers do methods.observe(self, other.frontiers[i]) end
    if other.permanent then self.permanent = true end
    self.reason = self.reason or other.reason
  else
    for i = 1, #other do methods.add(self, other[i]) end
  end
  return self
end

function methods:is_empty() return #self == 0 and #self.frontiers == 0 and #self.interests == 0 and not self.permanent end
function methods:has_interests() return #self.interests > 0 end
function methods:is_permanent() return self.permanent == true end
function methods:debug_observations() return self end

RetryProof.__index = methods
return RetryProof
