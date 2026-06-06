local Result = require('et.algebra.result')
local Candidate = require('et.algebra.candidate')
local Eval = require('et.algebra.eval')
local Rendezvous = require('et.solver.rendezvous')
local State = require('et.solver.state')
local World = require('et.solver.world')

local Search = {}

local clone_candidate = Candidate.clone
local process_one_deferred = Eval.process_one_deferred
local normalise_result = Eval.normalise_result
local eval_op = Eval.eval_op
local new_rendezvous_index = Rendezvous.new_index
local find_rendezvous_choices = Rendezvous.find_choices

local combo_order_sum = State.combo_order_sum
local closed_world = State.closed_world
local state_with_match = State.with_match
local state_with_deferred_branch = State.with_deferred_branch

local function combo_better(combo, _pref, best, _best_pref, best_order)
  if not best then return true end
  return combo_order_sum(combo) < best_order
end

local function sort_candidates(cs)
  table.sort(cs, function(a, b) return (a.order or 0) < (b.order or 0) end)
end

local function new_search_context(rt, opts)
  return { rt = rt, opts = opts or {}, order = 0, best_pref = nil, waits = nil, residuals = nil, residual_counts = {} }
end

local function assign_candidate_order(sctx, c)
  sctx.order = (sctx.order or 0) + 1
  c.order = sctx.order
end

local function status_from_waits(waits)
  if waits and #waits > 0 then
    return { tag = 'pending', kind = 'wakeup', reason = 'waiting for external wakeup', waits = waits }
  end
  return { tag = 'absent', reason = 'no compatible transaction' }
end


local function resource_compatible_so_far(selected)
  return State.resource_ok(selected, false)
end



local function solve_from_seed(seed, lists, ctx, out, limit, rendezvous_index)
  local selected = { clone_candidate(seed) }
  local selected_by_fiber = {}
  if selected[1].fiber then selected_by_fiber[selected[1].fiber] = true end

  local function rec(sel, by_fiber)
    if #out >= limit then return end
    for ci = 1, #sel do
      local branches = process_one_deferred(sel[ci], ctx)
      if branches then
        ctx.waits = Result._unique_append(ctx.waits, branches.waits)
        ctx.residuals = Result._unique_append(ctx.residuals, branches.residuals)
        for bi = 1, #branches.cands do
          local ns, nb = state_with_deferred_branch(sel, by_fiber, ci, branches.cands[bi])
          if ns then rec(ns, nb) end
        end
        return
      end
    end

    if not resource_compatible_so_far(sel) then return end

    local ci, ei, _e, matches = find_rendezvous_choices(sel, by_fiber, lists, seed.order or 0, rendezvous_index)
    if not ci then
      out[#out + 1] = sel
      return
    end
    if #matches == 0 then return end

    for mi = 1, #matches do
      local ns, nb = state_with_match(sel, by_fiber, ci, ei, matches[mi])
      if ns then rec(ns, nb) end
    end
  end

  rec(selected, selected_by_fiber)
end


local function candidate_lists_unbounded(rt, waiting, sctx)
  sctx = sctx or new_search_context(rt)
  local lists = {}
  local total_endpoints = 0
  local total_candidates = 0
  for i = 1, #waiting do
    local f = waiting[i]
    local ctx = {
      rt = rt,
      attempt = f.waiting.attempt,
      overlay = nil,
      origin = nil,
      fiber_id = i,
      residual_open = sctx.residual_open,
      residual_counts = sctx.residual_counts,
    }
    local r = normalise_result(eval_op(f.waiting.op, ctx), ctx)
    sctx.waits = Result._unique_append(sctx.waits, r.waits)
    sctx.residuals = Result._unique_append(sctx.residuals, r.residuals)
    local cs = r.cands
    for j = 1, #cs do
      cs[j].fiber = f
      assign_candidate_order(sctx, cs[j])
      total_endpoints = total_endpoints + #(cs[j].endpoints or {})
    end
    total_candidates = total_candidates + #cs
    if #cs > 1 then sort_candidates(cs) end
    lists[i] = cs
  end
  return lists, total_endpoints, total_candidates
end

local function solve_once(rt, waiting, opts, residual_open)
  local sctx = new_search_context(rt, opts)
  sctx.residual_open = residual_open
  local lists, total_endpoints, total_candidates = candidate_lists_unbounded(rt, waiting, sctx)
  if #waiting == 1 and total_endpoints == 0 then
    local list = lists[1] or {}
    for j = 1, #list do
      local cand = list[j]
      if #(cand.deferred or {}) == 0 then
        local w = closed_world({ cand })
        if w then return World.with_absence_proved(w), w.pref end
      end
    end
  end
  local rendezvous_index = new_rendezvous_index(lists, total_endpoints, total_candidates)
  local best, best_pref, best_order = nil, nil, nil

  for i = 1, #lists do
    local list = lists[i]
    for j = 1, #list do
      local cand = list[j]
      if #(cand.endpoints or {}) == 0 and #(cand.deferred or {}) == 0 then
        local w = closed_world({ cand })
        if w and combo_better(w.combo, w.pref, best and best.combo, best_pref, best_order) then
          best, best_pref, best_order = w, w.pref, w.order
          sctx.best_pref = best_pref
        end
      else
        local sols = {}
        solve_from_seed(cand, lists, sctx, sols, opts and opts.solution_limit or 64, rendezvous_index)
        for s = 1, #sols do
          local w = closed_world(sols[s])
          if w and combo_better(w.combo, w.pref, best and best.combo, best_pref, best_order) then
            best, best_pref, best_order = w, w.pref, w.order
            sctx.best_pref = best_pref
          end
        end
      end
    end
  end
  if best then return World.with_absence_proved(best), best_pref, nil, sctx.residuals end
  return nil, nil, status_from_waits(sctx.waits), sctx.residuals
end

local function copy_open(open, id)
  local t = {}
  if open then for k, v in pairs(open) do t[k] = v end end
  if id then t[id] = true end
  return t
end

local function open_key(open)
  if not open then return '' end
  local xs = {}
  for k in pairs(open) do xs[#xs + 1] = k end
  table.sort(xs)
  return table.concat(xs, '|')
end

local function append_unique(dst, src)
  return Result._unique_append(dst, src)
end


local function residual_score(open, pref)
  if not open then return pref end
  local n = 0
  for _ in pairs(open) do n = n + 1 end
  if n == 0 then return pref end
  return { n }
end

local function solve_unbounded(rt, waiting, opts)
  local queue = { { open = nil } }
  local seen = { [''] = true }
  local head = 1
  local terminal_waits = nil

  while head <= #queue do
    local env = queue[head]
    head = head + 1

    local world, pref, status, residuals = solve_once(rt, waiting, opts, env.open)
    if world then return world, residual_score(env.open, pref) end

    if residuals and #residuals > 0 then
      table.sort(residuals, function(a, b) return (a.order or 0) < (b.order or 0) end)
      for i = 1, #residuals do
        local open = copy_open(env.open, residuals[i].id)
        local key = open_key(open)
        if not seen[key] then
          seen[key] = true
          queue[#queue + 1] = { open = open }
        end
      end
    else
      terminal_waits = append_unique(terminal_waits, status and status.waits)
    end
  end

  return nil, nil, status_from_waits(terminal_waits)
end


Search.solve = solve_unbounded
Search.combo_order_sum = combo_order_sum
Search.combo_better = combo_better
Search.sort_candidates = sort_candidates
Search.new_search_context = new_search_context
Search.assign_candidate_order = assign_candidate_order
Search.status_from_waits = status_from_waits
Search.solve_from_seed = solve_from_seed

return Search
