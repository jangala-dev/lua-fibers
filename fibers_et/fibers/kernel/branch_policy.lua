-- Structural branch analysis shared by the production and reference machines.
--
-- The policy chooses a most-constrained exchange occurrence and orders claim
-- groups by domain size.  It does not decide semantic compatibility; callers
-- supply that predicate because product-lane compatibility belongs to the
-- evaluator state.

local M = {}

local function active_intent(state, id)
  if state.intent_by_id then return state.intent_by_id[id] end
  for i = 1, #(state.intents or {}) do
    if state.intents[i].id == id then return state.intents[i] end
  end
end

local function append_pair(pairs, degrees, left, right, compatible)
  if not left or not right then return end
  if not compatible(left, right) then return end
  pairs[#pairs + 1] = { left = left.id, right = right.id }
  degrees[left.id] = (degrees[left.id] or 0) + 1
  degrees[right.id] = (degrees[right.id] or 0) + 1
end

function M.exchange_frontier(state, compatible, constrained)
  local pairs, degrees = {}, {}
  local scans = 0
  if state.exchange_index and state.exchange_resources then
    for ri = 1, #state.exchange_resources do
      local resource = state.exchange_resources[ri]
      local bucket = state.exchange_index[resource]
      if bucket then
        for pi = 1, #(bucket.put or {}) do
          local put = active_intent(state, bucket.put[pi])
          if put then
            for gi = 1, #(bucket.get or {}) do
              local get = active_intent(state, bucket.get[gi])
              if get then
                scans = scans + 1
                append_pair(pairs, degrees, put, get, compatible)
              end
            end
          end
        end
      end
    end
  else
    for i = 1, #(state.intents or {}) do
      for j = i + 1, #(state.intents or {}) do
        local a, b = state.intents[i], state.intents[j]
        if a.kind == 'exchange' and b.kind == 'exchange' and a.resource == b.resource and a.role ~= b.role then
          scans = scans + 1
          append_pair(pairs, degrees, a, b, compatible)
        end
      end
    end
  end

  local selected, selected_degree
  local zero = 0
  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    if intent.kind == 'exchange' then
      local degree = degrees[intent.id] or 0
      if degree == 0 then
        zero = zero + 1
      elseif selected_degree == nil or degree < selected_degree
          or (degree == selected_degree and intent.id < selected.id) then
        selected, selected_degree = intent, degree
      end
    end
  end

  local ordered = {}
  if constrained == false then
    for i = 1, #pairs do ordered[i] = pairs[i] end
  elseif selected then
    for i = 1, #pairs do
      local pair = pairs[i]
      if pair.left == selected.id or pair.right == selected.id then ordered[#ordered + 1] = pair end
    end
    table.sort(ordered, function(a, b)
      local ap = a.left == selected.id and a.right or a.left
      local bp = b.left == selected.id and b.right or b.left
      if ap ~= bp then return ap < bp end
      if a.left ~= b.left then return a.left < b.left end
      return a.right < b.right
    end)
  end

  return {
    pairs = ordered,
    all_pairs = pairs,
    selected = selected,
    selected_degree = selected_degree or 0,
    scans = scans,
    compatible = #pairs,
    zero_domains = zero,
  }
end

function M.order_claim_groups(groups, constrained)
  if not constrained then return groups end
  table.sort(groups, function(a, b)
    if #a.ids ~= #b.ids then return #a.ids < #b.ids end
    local ai = a.ids[1] or math.huge
    local bi = b.ids[1] or math.huge
    if ai ~= bi then return ai < bi end
    return tostring(a.key) < tostring(b.key)
  end)
  return groups
end

return M
