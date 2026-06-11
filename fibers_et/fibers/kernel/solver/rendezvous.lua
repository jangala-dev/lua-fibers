local Topology = require('fibers.kernel.solver.topology')
local Candidate = require('fibers.kernel.algebra.candidate')

local Rendezvous = {}


function Rendezvous.remove(c, idx)
  table.remove(c.endpoints, idx)
end

function Rendezvous.match(a, b)
  if a.key ~= b.key or a.role == b.role then return false end
  if a.primitive ~= b.primitive then return false end
  return true
end

function Rendezvous.resolve_pair(ca, a, cb, b)
  local ar, br = a.role, b.role
  local get_c, get, put_c, put
  if ar == 'get' then
    get_c, get, put_c, put = ca, a, cb, b
  elseif br == 'get' then
    get_c, get, put_c, put = cb, b, ca, a
  else
    return
  end
  Candidate.subst_bind(get_c, get.ph, Candidate.resolve(put.value, put_c and put_c.subst))
end

function Rendezvous.internal_close(c)
  local changed = true
  while changed do
    changed = false
    for i = 1, #c.endpoints do
      local a = c.endpoints[i]
      for j = i + 1, #c.endpoints do
        local b = c.endpoints[j]
        if Rendezvous.match(a, b) and Topology.internal_allowed(a, b) then
          Rendezvous.resolve_pair(c, a, c, b)
          table.remove(c.endpoints, j)
          table.remove(c.endpoints, i)
          changed = true
          break
        end
      end
      if changed then break end
    end
  end
end

local function opposite_role(r)
  if r == 'get' then return 'put' else return 'get' end
end

function Rendezvous.new_index(lists, endpoint_count, candidate_count)
  if (endpoint_count or 0) < 8 or (candidate_count or 0) < 8 then return nil end
  local idx = { get = {}, put = {}, by_key = {}, endpoint_count = endpoint_count }
  for li = 1, #lists do
    local list = lists[li]
    for ci = 1, #list do
      local cand = list[ci]
      for ei = 1, #(cand.endpoints or {}) do
        local e = cand.endpoints[ei]
        local r, k = e.role, e.key
        local bucket = idx[r][k]
        if not bucket then bucket = {}; idx[r][k] = bucket end
        local n = #bucket
        bucket[n + 1] = cand
        bucket[n + 2] = ei
        idx.by_key[k] = true
      end
    end
  end
  return idx
end

local function find_scan(selected, selected_by_fiber, lists, min_order)
  local best = nil
  local best_matches = nil
  local best_count = nil
  for ci = 1, #selected do
    local c = selected[ci]
    for ei = 1, #c.endpoints do
      local e = c.endpoints[ei]
      local matches, count = {}, 0
      for cj = 1, #selected do
        local start = 1
        if cj == ci then start = ei + 1 end
        for ej = start, #selected[cj].endpoints do
          if cj ~= ci then
            local f = selected[cj].endpoints[ej]
            if Rendezvous.match(e, f) then
              count = count + 1
              matches[count] = { kind = 'selected', ci = cj, ei = ej }
            end
          end
        end
      end
      for li = 1, #lists do
        local list = lists[li]
        for cj = 1, #list do
          local cand = list[cj]
          if cand.fiber and not selected_by_fiber[cand.fiber] and ((cand.order or 0) > (min_order or 0)) then
            for ej = 1, #cand.endpoints do
              if Rendezvous.match(e, cand.endpoints[ej]) then
                count = count + 1
                matches[count] = { kind = 'new', cand = cand, ei = ej }
                break
              end
            end
          end
        end
      end
      if count == 0 then return ci, ei, e, {} end
      if best_count == nil or count < best_count then
        best, best_matches, best_count = { ci = ci, ei = ei, e = e }, matches, count
      end
    end
  end
  if best then return best.ci, best.ei, best.e, best_matches end
  return nil
end

function Rendezvous.find_choices(selected, selected_by_fiber, lists, min_order, rendezvous_index)
  if not rendezvous_index then return find_scan(selected, selected_by_fiber, lists, min_order) end
  local best = nil
  local best_matches = nil
  local best_count = nil
  for ci = 1, #selected do
    local c = selected[ci]
    for ei = 1, #c.endpoints do
      local e = c.endpoints[ei]
      local matches, count = {}, 0
      for cj = 1, #selected do
        local start_e = 1
        if cj == ci then start_e = ei + 1 end
        for ej = start_e, #selected[cj].endpoints do
          if cj ~= ci then
            local f = selected[cj].endpoints[ej]
            if Rendezvous.match(e, f) then
              count = count + 1
              matches[count] = { kind = 'selected', ci = cj, ei = ej }
            end
          end
        end
      end
      local bucket = rendezvous_index[opposite_role(e.role)] and rendezvous_index[opposite_role(e.role)][e.key]
      if bucket then
        for bi = 1, #bucket, 2 do
          local cand = bucket[bi]
          if cand.fiber and not selected_by_fiber[cand.fiber] and (cand.order or 0) > (min_order or 0) then
            count = count + 1
            matches[count] = { kind = 'new', cand = cand, ei = bucket[bi + 1] }
          end
        end
      end
      if count == 0 then return ci, ei, e, {} end
      if best_count == nil or count < best_count then
        best, best_matches, best_count = { ci = ci, ei = ei, e = e }, matches, count
        if count == 1 then return best.ci, best.ei, best.e, best_matches end
      end
    end
  end
  if best then return best.ci, best.ei, best.e, best_matches end
  return nil
end

return Rendezvous
