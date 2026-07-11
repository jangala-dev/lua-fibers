-- Lazy RetryProof construction shared by direct resource evaluation and
-- premise resolution. State is stored on the caller's existing context so
-- successful paths allocate no separate builder object.

local RetryProof = require('fibers.kernel.retry')

local RetryBuilder = {}

local function same_interest(a, b)
  if a == b then return true end
  if not a or not b then return false end
  return (a.id or a.key) == (b.id or b.key)
end

function RetryBuilder.init(ctx, opts)
  opts = opts or {}
  ctx._retry_debug = opts.debug == true
  ctx._retry_reason = opts.reason
  return ctx
end

function RetryBuilder.observe(ctx, frontier)
  if not frontier then return frontier end
  local proof = rawget(ctx, '_retry_materialised')
  if proof then proof:observe(frontier); return frontier end
  local first = rawget(ctx, '_retry_frontier')
  if first == nil then
    ctx._retry_frontier = frontier
  elseif first ~= frontier then
    local more = rawget(ctx, '_retry_frontiers')
    if not more then more = {}; ctx._retry_frontiers = more end
    for i = 1, #more do if more[i] == frontier then return frontier end end
    more[#more + 1] = frontier
  end
  return frontier
end

function RetryBuilder.add_interest(ctx, interest)
  if not interest then return interest end
  local proof = rawget(ctx, '_retry_materialised')
  if proof then proof:add_interest(interest); return interest end
  local first = rawget(ctx, '_retry_interest')
  if first == nil then
    ctx._retry_interest = interest
  elseif not same_interest(first, interest) then
    local more = rawget(ctx, '_retry_interests')
    if not more then more = {}; ctx._retry_interests = more end
    for i = 1, #more do if same_interest(more[i], interest) then return interest end end
    more[#more + 1] = interest
  end
  return interest
end

function RetryBuilder.add(ctx, observation)
  if not observation then return observation end
  RetryBuilder.observe(ctx, observation.frontier)
  if not rawget(ctx, '_retry_debug') then return observation end
  local proof = rawget(ctx, '_retry_materialised')
  if proof then proof:add(observation); return observation end
  local observations = rawget(ctx, '_retry_observations')
  if not observations then observations = {}; ctx._retry_observations = observations end
  observations[#observations + 1] = observation
  return observation
end

function RetryBuilder.set_reason(ctx, reason)
  if reason and not rawget(ctx, '_retry_reason') then ctx._retry_reason = reason end
  local proof = rawget(ctx, '_retry_materialised')
  if proof and not proof.reason then proof.reason = ctx._retry_reason end
  return ctx
end

function RetryBuilder.materialise(ctx)
  local proof = rawget(ctx, '_retry_materialised')
  if proof then return proof end
  proof = RetryProof.new(nil, nil, { reason = rawget(ctx, '_retry_reason') })
  local first = rawget(ctx, '_retry_frontier')
  if first then proof:observe(first) end
  for i = 1, #(rawget(ctx, '_retry_frontiers') or {}) do proof:observe(ctx._retry_frontiers[i]) end
  for i = 1, #(rawget(ctx, '_retry_observations') or {}) do proof:add(ctx._retry_observations[i]) end
  local interest = rawget(ctx, '_retry_interest')
  if interest then proof:add_interest(interest) end
  for i = 1, #(rawget(ctx, '_retry_interests') or {}) do proof:add_interest(ctx._retry_interests[i]) end
  ctx._retry_materialised = proof
  return proof
end

return RetryBuilder
