-- Pure blocked-frontier classification shared by the production and reference
-- evaluators.  The analyser does not mutate evaluator state or open witness
-- cursors.  It records the current domains and leaves semantic actions to the
-- machine which owns the state.

local IR = require('fibers.internal.kernel.ir')

local M = {}

local function clear_array(values)
  for i = #values, 1, -1 do
    values[i] = nil
  end
end

function M.new_scratch()
  local pair = {}
  local pairs = {}
  local exchange = {}
  local result = {}
  return {
    pair = pair,
    pairs = pairs,
    exchange = exchange,
    witnesses = {},
    claims = {},
    result = result,
  }
end

function M.clear_scratch(scratch)
  if not scratch then
    return
  end
  clear_array(scratch.pairs)
  clear_array(scratch.witnesses)
  clear_array(scratch.claims)
  for key in pairs(scratch.pair) do
    scratch.pair[key] = nil
  end
  for key in pairs(scratch.exchange) do
    scratch.exchange[key] = nil
  end
  for key in pairs(scratch.result) do
    scratch.result[key] = nil
  end
end

local function small_exchange_frontier(state, compatible, constrained, scratch)
  local count = #state.intents
  if count > 2 then
    return nil
  end
  for i = 1, count do
    if state.intents[i].kind ~= 'exchange' then
      return nil
    end
  end

  M.clear_scratch(scratch)
  local pairs = scratch.pairs
  local exchange = scratch.exchange
  local selected, selected_degree, scans, compatible_count, zero = nil, 0, 0, 0, count

  if count == 2 then
    local left, right = state.intents[1], state.intents[2]
    if left.resource == right.resource and left.role ~= right.role then
      scans = 1
      if compatible(left, right) then
        local pair = scratch.pair
        pair.left, pair.right = left.id, right.id
        pairs[1] = pair
        compatible_count = 1
        zero = 0
        if constrained ~= false then
          selected = left.id < right.id and left or right
          selected_degree = 1
        end
      end
    end
  end

  exchange.pairs = pairs
  exchange.all_pairs = pairs
  exchange.selected = selected
  exchange.selected_degree = selected_degree
  exchange.scans = scans
  exchange.compatible = compatible_count
  exchange.zero_domains = zero
  exchange.symmetry_pruned = 0

  local result = scratch.result
  result.exchange = exchange
  result.witnesses = scratch.witnesses
  result.claims = scratch.claims
  result.accepts_participant_supply = count > 0
  result._scratch = true
  return result
end

function M.detach(frontier)
  if not frontier or not frontier._scratch then
    return frontier
  end
  local exchange = frontier.exchange
  local pairs = {}
  for i = 1, #(exchange.pairs or {}) do
    local pair = exchange.pairs[i]
    pairs[i] = { left = pair.left, right = pair.right }
  end
  return {
    exchange = {
      pairs = pairs,
      all_pairs = pairs,
      selected = exchange.selected,
      selected_degree = exchange.selected_degree,
      scans = exchange.scans,
      compatible = exchange.compatible,
      zero_domains = exchange.zero_domains,
      symmetry_pruned = exchange.symmetry_pruned,
    },
    witnesses = {},
    claims = {},
    accepts_participant_supply = frontier.accepts_participant_supply,
  }
end

local function active_intent(state, id)
  if state.intent_by_id then
    return state.intent_by_id[id]
  end
  for i = 1, #(state.intents or {}) do
    if state.intents[i].id == id then
      return state.intents[i]
    end
  end
end

local function append_pair(pairs, degrees, left, right, compatible)
  if not left or not right then
    return
  end
  if not compatible(left, right) then
    return
  end
  pairs[#pairs + 1] = { left = left.id, right = right.id }
  degrees[left.id] = (degrees[left.id] or 0) + 1
  degrees[right.id] = (degrees[right.id] or 0) + 1
end

function M.exchange_frontier(state, compatible, constrained)
  local pairs, degrees = {}, {}
  local scans = 0
  for i = 1, #(state.intents or {}) do
    for j = i + 1, #(state.intents or {}) do
      local a, b = state.intents[i], state.intents[j]
      if a.kind == 'exchange' and b.kind == 'exchange' and a.resource == b.resource and a.role ~= b.role then
        scans = scans + 1
        append_pair(pairs, degrees, a, b, compatible)
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
      elseif
        selected_degree == nil
        or degree < selected_degree
        or (degree == selected_degree and intent.id < selected.id)
      then
        selected, selected_degree = intent, degree
      end
    end
  end

  local ordered, symmetry_pruned = {}, 0
  if constrained == false then
    for i = 1, #pairs do
      ordered[i] = pairs[i]
    end
  elseif selected then
    local seen_symmetry = {}
    for i = 1, #pairs do
      local pair = pairs[i]
      if pair.left == selected.id or pair.right == selected.id then
        local partner_id = pair.left == selected.id and pair.right or pair.left
        local partner = active_intent(state, partner_id)
        local key = partner and partner.symmetry_key
        if key ~= nil and state.runtime and state.runtime.certified_symmetry then
          local signature = table.concat({
            type(key),
            tostring(key),
            tostring(partner.kind or ''),
            tostring(partner.resource or ''),
            tostring(partner.role or ''),
            type(partner.value),
            tostring(partner.value),
          }, ':')
          if seen_symmetry[signature] then
            symmetry_pruned = symmetry_pruned + 1
          else
            seen_symmetry[signature] = true
            ordered[#ordered + 1] = pair
          end
        else
          ordered[#ordered + 1] = pair
        end
      end
    end
    table.sort(ordered, function(a, b)
      local ap = a.left == selected.id and a.right or a.left
      local bp = b.left == selected.id and b.right or b.left
      if ap ~= bp then
        return ap < bp
      end
      if a.left ~= b.left then
        return a.left < b.left
      end
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
    symmetry_pruned = symmetry_pruned,
  }
end

function M.order_claim_groups(groups, constrained)
  if not constrained then
    return groups
  end
  table.sort(groups, function(a, b)
    if #a.ids ~= #b.ids then
      return #a.ids < #b.ids
    end
    local ai = a.ids[1] or math.huge
    local bi = b.ids[1] or math.huge
    if ai ~= bi then
      return ai < bi
    end
    return tostring(a.key) < tostring(b.key)
  end)
  return groups
end

local function transition_rule(intent)
  if intent and intent.kind == 'transition' then
    return IR.rule(intent.program)
  end
end

local function accepts_participant_supply(intent)
  if not intent then
    return false
  end
  if intent.kind == 'exchange' then
    return true
  end
  local rule = transition_rule(intent)
  return rule and rule.accepts_supply == true or false
end

local function claim_frontier(state, constrained)
  local by_key, groups = {}, {}
  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    local rule = transition_rule(intent)
    if rule and not rule.enumerable then
      local key = intent.program.group or intent.program.location
      local group = by_key[key]
      if not group then
        group = {
          key = key,
          ids = {},
          intents = {},
          all_machine = true,
          accepts_supply = false,
        }
        by_key[key] = group
        groups[#groups + 1] = group
      end
      group.ids[#group.ids + 1] = intent.id
      group.intents[#group.intents + 1] = intent
      if not rule.serial then
        group.all_machine = false
        group.accepts_supply = true
      elseif rule.accepts_supply then
        group.accepts_supply = true
      end
    end
  end
  return M.order_claim_groups(groups, constrained)
end

function M.analyse(state, compatible, constrained, scratch)
  if scratch then
    local small = small_exchange_frontier(state, compatible, constrained, scratch)
    if small then
      return small
    end
  end
  local witnesses = {}
  local accepts_supply = false
  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    local rule = transition_rule(intent)
    if rule and rule.enumerable then
      witnesses[#witnesses + 1] = intent
    end
    if accepts_participant_supply(intent) then
      accepts_supply = true
    end
  end

  return {
    exchange = M.exchange_frontier(state, compatible, constrained),
    witnesses = witnesses,
    claims = claim_frontier(state, constrained),
    accepts_participant_supply = accepts_supply,
  }
end

return M
