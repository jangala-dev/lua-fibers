-- Small internal helpers for premise-based resources.

local Premise = {}

function Premise.record_from_view(view)
  return view and view.rec or view
end

function Premise.sibling_supply_hidden(view)
  return view and view.relation == 'sibling' and view.mode == 'independent'
end

function Premise.project_selective(initial, views, opts)
  local value = initial
  views = views or {}
  opts = opts or {}
  for i = 1, #views do
    local view = views[i]
    local rec = Premise.record_from_view(view)
    if rec and (not opts.changed or opts.changed(rec)) then
      local candidate = opts.apply and opts.apply(value, rec, view) or value
      if Premise.sibling_supply_hidden(view) then
        local before = opts.succeeds and opts.succeeds(value)
        local after = opts.succeeds and opts.succeeds(candidate)
        if before and not after then value = candidate end
      else
        value = candidate
      end
    end
  end
  return value
end

function Premise.sort_by_id(ps)
  table.sort(ps, function(a, b) return (a.id or 0) < (b.id or 0) end)
  return ps
end

function Premise.pairwise_compatible(ps, ctx)
  for i = 1, #ps do
    for j = i + 1, #ps do
      if ctx.compatible and not ctx:compatible(ps[i], ps[j]) then return false end
    end
  end
  return true
end

function Premise.filter(premises, pred)
  local out = {}
  for i = 1, #(premises or {}) do
    if pred(premises[i]) then out[#out + 1] = premises[i] end
  end
  return Premise.sort_by_id(out)
end

function Premise.clone_bool_map(m)
  local out = {}
  for k, v in pairs(m or {}) do if v then out[k] = true end end
  return out
end

function Premise.clone_map(m, clone_value)
  local out = {}
  for k, v in pairs(m or {}) do out[k] = clone_value and clone_value(v) or v end
  return out
end

function Premise.map_empty(m)
  for _ in pairs(m or {}) do return false end
  return true
end

return Premise
