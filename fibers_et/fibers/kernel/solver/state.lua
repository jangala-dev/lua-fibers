local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Rendezvous = require('fibers.kernel.solver.rendezvous')
local World = require('fibers.kernel.solver.world')

local State = {}

local clone_candidate = Candidate.clone
local raw_resolved = Candidate.raw_resolved
local rendezvous_match = Rendezvous.match
local resolve_pair = Rendezvous.resolve_pair
local remove_rendezvous = Rendezvous.remove

local function combo_order_sum(combo)
  local s = 0
  for i = 1, #combo do s = s + (combo[i].order or 0) end
  return s
end

local function clone_selected(selected, selected_by_fiber)
  local ns, nb = {}, {}
  for i = 1, #selected do
    local c = clone_candidate(selected[i])
    ns[i] = c
    if c.fiber then nb[c.fiber] = true end
  end
  for k, v in pairs(selected_by_fiber or {}) do nb[k] = v end
  return ns, nb
end

local function resource_ok(selected, require_resolved)
  local ok, reason = Resource.structural_compatible(selected, require_resolved, raw_resolved)
  if not ok then return false, reason end
  local cok, creason = Candidate.consequences_compatible(selected)
  if not cok then return false, creason end
  return true
end

local function closed_world(combo)
  if not resource_ok(combo, true) then return nil end
  return World.closed(combo, nil, combo_order_sum(combo))
end

local function close_selected_match(ns, ci, ei, m)
  local c1, c2 = ns[ci], ns[m.ci]
  local e1, e2 = c1 and c1.endpoints[ei], c2 and c2.endpoints[m.ei]
  if not (e1 and e2 and rendezvous_match(e1, e2)) then return false end

  resolve_pair(c1, e1, c2, e2)
  if m.ci > ci or (m.ci == ci and m.ei > ei) then
    remove_rendezvous(c2, m.ei)
    remove_rendezvous(c1, ei)
  else
    remove_rendezvous(c1, ei)
    remove_rendezvous(c2, m.ei)
  end
  return true
end

local function close_new_match(ns, nb, ci, ei, m)
  local nc = clone_candidate(m.cand)
  ns[#ns + 1] = nc
  if nc.fiber then nb[nc.fiber] = true end

  local c1 = ns[ci]
  local e1, e2 = c1 and c1.endpoints[ei], nc.endpoints[m.ei]
  if not (e1 and e2 and rendezvous_match(e1, e2)) then return false end

  resolve_pair(c1, e1, nc, e2)
  remove_rendezvous(nc, m.ei)
  remove_rendezvous(c1, ei)
  return true
end

local function with_match(selected, selected_by_fiber, ci, ei, m)
  local ns, nb = clone_selected(selected, selected_by_fiber)
  local ok
  if m.kind == 'selected' then
    ok = close_selected_match(ns, ci, ei, m)
  else
    ok = close_new_match(ns, nb, ci, ei, m)
  end
  if not ok then return nil end
  return ns, nb
end

local function with_deferred_branch(selected, selected_by_fiber, ci, branch)
  local ns, nb = clone_selected(selected, selected_by_fiber)
  ns[ci] = branch
  if branch.fiber then nb[branch.fiber] = true end
  if not resource_ok(ns, false) then return nil end
  return ns, nb
end

State.combo_order_sum = combo_order_sum
State.clone_selected = clone_selected
State.resource_ok = resource_ok
State.closed_world = closed_world
State.close_selected_match = close_selected_match
State.close_new_match = close_new_match
State.with_match = with_match
State.with_deferred_branch = with_deferred_branch

return State
