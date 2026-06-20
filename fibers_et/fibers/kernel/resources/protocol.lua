-- Open-world resource participation protocol for the semantic transaction net.
--
-- Resource proposals carry sparse records:
--   proposal.res[resource] = record
--   record.kind            = capability table
--
-- The generic layer does not know whether a record belongs to a cell, region,
-- flow reservoir, endpoint, queue, or future resource.  The resource kind owns
-- clone, sequential/parallel merge, projection, preparation and application.
-- Kinds may also expose `absence(resource, payload, ctx)`; or_else fallback
-- worlds then validate the specific mutable facts named by the resource kind.

local EffectSet = require('fibers.kernel.effect.set')

local Resource = {}

local function kind_name(kind)
  return kind and kind.name or tostring(kind)
end

local function clone_record(rec)
  local clone = rec.kind and rec.kind.clone
  if clone then return clone(rec) end

  local out = {}
  for k, v in pairs(rec) do out[k] = v end
  return out
end

local function ensure(c, r, kind)
  local map = c.res
  if not map then
    map = {}
    c.res = map
    c.res_list = {}
  end

  local rec = map[r]
  if not rec then
    rec = { kind = kind }
    map[r] = rec
    c.res_list[#c.res_list + 1] = r
  end

  if rec.kind ~= kind then return nil, 'resource-kind-conflict' end
  return rec
end

function Resource.ensure(c, r, kind)
  return ensure(c, r, kind)
end

function Resource.copy_from(dst, src)
  local list = src and src.res_list
  if not list then return end
  for i = 1, #list do
    local r = list[i]
    if src.res and src.res[r] then
      if not dst.res then dst.res = {}; dst.res_list = {} end
      dst.res[r] = clone_record(src.res[r])
      dst.res_list[#dst.res_list + 1] = r
    end
  end
end

local function merge_record(dst, src, method)
  if dst.kind ~= src.kind then return false, 'resource-kind-conflict' end
  local f = dst.kind and dst.kind[method]
  if not f then return false, 'unknown-resource-kind:' .. kind_name(dst.kind) end
  return f(dst, src)
end

local function merge_into(dst, src, method)
  local list = src and src.res_list
  if not list then return true end

  for i = 1, #list do
    local r = list[i]
    local srec = src.res[r]
    local drec, why = ensure(dst, r, srec.kind)
    if not drec then return false, why end

    local ok, reason = merge_record(drec, srec, method)
    if not ok then return false, reason end
  end

  return true
end

function Resource.merge_seq_into(dst, src)
  return merge_into(dst, src, 'merge_seq')
end

function Resource.merge_parallel_into(dst, src)
  return merge_into(dst, src, 'merge_par')
end

function Resource.project(ctx, resource, query)
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[resource]
  if rec and rec.kind and rec.kind.project then
    local v, ok = rec.kind.project(resource, rec, query)
    if ok then return v end
  end

  local kind = resource and resource._fibers_kind
  if kind and kind.project then
    local v, ok = kind.project(resource, nil, query)
    if ok then return v end
  end

  return nil
end

function Resource.overlay_from(c, parent)
  if not parent and not (c and c.res_list) then return nil end

  local overlay = { res = nil, res_list = nil }
  if parent then Resource.merge_seq_into(overlay, parent) end
  Resource.merge_seq_into(overlay, c)

  if not overlay.res_list then return nil end
  return overlay
end

local function merge_combo_parallel(combo, require_resolved, raw_resolved)
  local n = #combo

  if n == 1 then
    local c = combo[1]
    if require_resolved and not raw_resolved(c.vals, c.subst) then return false, nil, nil, 'unresolved' end
    return true, c.res, c.res_list, nil
  end

  local acc = { res = nil, res_list = nil }

  for ci = 1, n do
    local c = combo[ci]
    if require_resolved and not raw_resolved(c.vals, c.subst) then return false, nil, nil, 'unresolved' end

    local ok, reason = Resource.merge_parallel_into(acc, c)
    if not ok then return false, nil, nil, reason end
  end

  return true, acc.res, acc.res_list, nil
end

function Resource.structural_compatible(combo, require_resolved, raw_resolved)
  local ok, _map, _list, reason = merge_combo_parallel(combo, require_resolved, raw_resolved)
  return ok, reason
end

function Resource.prepare_combo(combo, raw_resolved, resolve)
  local has_resources = false
  local subst = nil
  for i = 1, #combo do
    local c = combo[i]
    if c.res_list then has_resources = true end
    if c.subst then
      if not subst then subst = {} end
      for k, v in pairs(c.subst) do subst[k] = v end
    end
  end
  if not has_resources then return nil end

  local ok, map, list, reason = merge_combo_parallel(combo, true, raw_resolved)
  if not ok then return nil, reason end

  local function resolve_with_subst(x)
    return resolve(x, subst)
  end

  local prepared = nil
  local derived = nil
  for i = 1, #list do
    local resource = list[i]
    local rec = map[resource]
    local prepare = rec.kind and rec.kind.prepare
    if not prepare then return nil, 'unknown-resource-kind:' .. kind_name(rec.kind) end

    local p, why, noop = prepare(resource, rec, resolve_with_subst)
    if why then return nil, why end
    if p and not noop then
      prepared = prepared or {}
      prepared[#prepared + 1] = p

      if p.effect_set then
        derived = derived or EffectSet.empty()
        local ok, err = derived:merge(p.effect_set)
        if not ok then return nil, err end
      elseif p.effects then
        derived = derived or EffectSet.empty()
        for j = 1, #p.effects do
          local ok, err = derived:add(p.effects[j])
          if not ok then return nil, err end
        end
      end
    end
  end

  return prepared, nil, derived
end

function Resource.apply_prepared(prepared, log)
  local apply = prepared.kind and prepared.kind.apply
  if not apply then error('unknown prepared resource kind ' .. kind_name(prepared.kind), 2) end
  return apply(prepared, log)
end

return Resource
