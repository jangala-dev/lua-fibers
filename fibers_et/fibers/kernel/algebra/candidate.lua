local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local EffectSet = require('fibers.kernel.effect.set')

local Candidate = {}
local pack_ = Op._pack
local overlay_from = Resource.overlay_from
local next_ph = 0

local function list_append(dst, src)
  if src then for i = 1, #src do dst[#dst + 1] = src[i] end end
end

local function list_copy(src)
  local dst = {}
  if src then for i = 1, #src do dst[i] = src[i] end end
  return dst
end

local function unique_append(dst, src)
  if not src then return end
  for i = 1, #src do
    local x, found = src[i], false
    for j = 1, #dst do if dst[j] == x then found = true; break end end
    if not found then dst[#dst + 1] = x end
  end
end

local function new_ph()
  next_ph = next_ph + 1
  return { _ph = true, id = next_ph }
end

local function is_ph(x) return type(x) == 'table' and x._ph end

local function is_structural_value(x)
  return type(x) == 'table' and (x._fibers_pack == true or x._fibers_rows == true)
end

local function is_opaque_value(x)
  return type(x) == 'table' and not is_structural_value(x)
end

local NIL = {}

local function subst_lookup(subst, ph)
  if not subst then return false, nil end
  local v = subst[ph.id]
  if v == nil then return false, nil end
  if v == NIL then return true, nil end
  return true, v
end

local function subst_bind(c, ph, value)
  local subst = c.subst
  if not subst then subst = {}; c.subst = subst end
  subst[ph.id] = (value == nil) and NIL or value
end

local function subst_copy(subst)
  if not subst then return nil end
  local out = {}
  for k, v in pairs(subst) do out[k] = v end
  return out
end

local function subst_merge(a, b)
  if not a then return subst_copy(b) end
  if not b then return subst_copy(a) end
  local out = subst_copy(a)
  for k, v in pairs(b) do
    local old = out[k]
    if old ~= nil and old ~= v then return nil, 'placeholder-conflict' end
    out[k] = v
  end
  return out
end

local function raw_resolved(x, subst, seen)
  if is_ph(x) then
    local ok, v = subst_lookup(subst, x)
    if ok then return raw_resolved(v, subst, seen) end
    return false
  elseif type(x) == 'table' then
    if is_opaque_value(x) then return true end
    if x._nack_ref then return true end
    if seen and seen[x] then return true end
    seen = seen or {}; seen[x] = true
    local n = x.n or #x
    for i = 1, n do if not raw_resolved(x[i], subst, seen) then return false end end
    return true
  else
    return true
  end
end

local function resolve(x, subst, seen)
  if is_ph(x) then
    local ok, v = subst_lookup(subst, x)
    if ok then return resolve(v, subst, seen) end
    return x
  elseif type(x) == 'table' then
    if is_opaque_value(x) then return x end
    if x._nack_ref then return x end
    if seen and seen[x] then return x end
    seen = seen or {}; seen[x] = true
    local y = {}
    if x._fibers_pack then y._fibers_pack = true end
    if x._fibers_rows then y._fibers_rows = true end
    if x.n ~= nil then y.n = x.n end
    local n = x.n or #x
    for i = 1, n do y[i] = resolve(x[i], subst, seen) end
    return y
  else
    return x
  end
end

local function resolve_pack(p, subst)
  local q = { _fibers_pack = true, n = p.n or #p }
  for i = 1, q.n do q[i] = resolve(p[i], subst) end
  return q
end

local function structural_clone(x, seen)
  if type(x) ~= 'table' then return x end
  if is_ph(x) or x._nack_ref or is_opaque_value(x) then return x end
  if seen and seen[x] then return seen[x] end
  seen = seen or {}
  local y = {}
  seen[x] = y
  if x._fibers_pack then y._fibers_pack = true end
  if x._fibers_rows then y._fibers_rows = true end
  if x.n ~= nil then y.n = x.n end
  local n = x.n or #x
  for i = 1, n do y[i] = structural_clone(x[i], seen) end
  return y
end

local function path_copy(path)
  if not path then return nil end
  local out = {}
  for i = 1, #path do out[i] = path[i] end
  return out
end

local function path_prepend(path, idx)
  local out = { idx }
  if path then for i = 1, #path do out[#out + 1] = path[i] end end
  return out
end

local function path_prefix(path, prefix)
  if prefix == nil then return path_copy(path) end
  if type(prefix) ~= 'table' then return path_prepend(path, prefix) end
  local out = path_copy(prefix) or {}
  if path then for i = 1, #path do out[#out + 1] = path[i] end end
  return out
end

local function same_path(a, b)
  if a == nil or #a == 0 then return b == nil or #b == 0 end
  if b == nil or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function deferred_copy(src, prefix)
  local dst = {}
  if src then
    for i = 1, #src do
      local d, copy = src[i], {}
      for k, v in pairs(d) do copy[k] = v end
      copy.path = path_prefix(d.path, prefix)
      dst[#dst + 1] = copy
    end
  end
  return dst
end

local function deferred_append(dst, src, prefix)
  if not src then return end
  for i = 1, #src do
    local d, copy = src[i], {}
    for k, v in pairs(d) do copy[k] = v end
    copy.path = path_prefix(d.path, prefix)
    dst[#dst + 1] = copy
  end
end

local function target_pack(c, path)
  local vals = c.vals
  if not path or #path == 0 then return vals end
  for i = 1, #path do
    if type(vals) ~= 'table' or not vals._fibers_pack then return nil end
    local rows = vals[1]
    if type(rows) ~= 'table' or not rows._fibers_rows then return nil end
    vals = rows[path[i]]
  end
  return vals
end

local function set_target_pack(c, path, new_vals)
  if not path or #path == 0 then
    c.vals = new_vals
    return true
  end
  local vals = c.vals
  for i = 1, #path - 1 do
    local rows = vals and vals[1]
    vals = rows and rows[path[i]]
  end
  local rows = vals and vals[1]
  if type(rows) ~= 'table' then return false end
  rows[path[#path]] = new_vals
  return true
end

local function deferred_target_resolved(c, d)
  local vals = target_pack(c, d.path)
  return vals ~= nil and raw_resolved(vals, c.subst)
end

local function deferred_target_values(c, d)
  local vals = target_pack(c, d.path)
  if not vals then return nil end
  return resolve_pack(vals, c.subst)
end

local function compose_slot_post(old_post, path, post)
  if not post then return old_post end
  if path == nil or #path == 0 then
    if not old_post then return post end
    return function(vals) return post(old_post(vals)) end
  end
  return function(vals)
    if old_post then vals = old_post(vals) end
    local holder = { vals = structural_clone(vals) }
    local target = target_pack(holder, path)
    local new_target = post(target)
    set_target_pack(holder, path, new_target)
    return holder.vals
  end
end

local function new(vals, role)
  return {
    role = role or 'template',
    vals = vals or pack_(),
    deferred = {},
    endpoints = {},
    effects = nil,
    post = nil,
    res = nil,
    res_list = nil,
    selected_nacks = {},
    lost_nacks = {},
    protected_nacks = {},
    order = 0,
  }
end

local function empty()
  return new(pack_())
end

local function clone(c)
  -- Values and placeholders are persistent search structure.  Branch-local
  -- rendezvous resolution lives in c.subst, so clone only copies the mutable
  -- frontier and shares value graphs.
  local d = new(structural_clone(c.vals), 'search')
  d.subst = subst_copy(c.subst)
  d.deferred = deferred_copy(c.deferred)
  d.endpoints = {}
  for i = 1, #(c.endpoints or {}) do
    local e, copy = c.endpoints[i], {}
    for k, v in pairs(e) do copy[k] = v end
    d.endpoints[i] = copy
  end
  d.effects = c.effects and c.effects:copy() or nil
  d.post = c.post
  Resource.copy_from(d, c)
  d.selected_nacks = list_copy(c.selected_nacks)
  d.lost_nacks = list_copy(c.lost_nacks)
  d.protected_nacks = list_copy(c.protected_nacks)
  d.order = c.order
  d.fiber = c.fiber
  return d
end


local function add_effect(c, effect)
  local set = c.effects
  if not set then
    set = EffectSet.empty()
    c.effects = set
  end
  return set:add(effect)
end

local function merge_effect_combo(combo)
  local set = nil
  for i = 1, #combo do
    local cs = combo[i].effects
    if cs then
      set = set or EffectSet.empty()
      local ok, err = set:merge(cs)
      if not ok then return nil, err or 'effect-conflict' end
    end
  end
  return set
end

local function effects_compatible(combo)
  local _set, err = merge_effect_combo(combo)
  return err == nil, err
end

local function ctx_with_overlay(ctx, c)
  local n = {}
  for k, v in pairs(ctx) do n[k] = v end
  n.overlay = overlay_from(c, ctx.overlay)
  return n
end

local function merge_common(a, b, out)
  if a.effects or b.effects then
    local set = a.effects and a.effects:copy() or EffectSet.empty()
    local ok, err = set:merge(b.effects)
    if not ok then return false, err or 'effect-conflict' end
    if not set:is_empty() then out.effects = set end
  end
  out.endpoints = list_copy(a.endpoints); list_append(out.endpoints, b.endpoints)
  out.selected_nacks = list_copy(a.selected_nacks); unique_append(out.selected_nacks, b.selected_nacks)
  out.lost_nacks = list_copy(a.lost_nacks); unique_append(out.lost_nacks, b.lost_nacks)
  out.protected_nacks = list_copy(a.protected_nacks); unique_append(out.protected_nacks, b.protected_nacks)
  out.fiber = a.fiber or b.fiber
  out.order = a.order or b.order or 0
  local subst, why = subst_merge(a.subst, b.subst)
  if why then return false, why end
  out.subst = subst
  Resource.copy_from(out, a)
  return true
end

local function combine_seq(a, b, tail)
  local out = new(b.vals, a.role or b.role)
  if not merge_common(a, b, out) then return nil end
  Resource.merge_seq_into(out, b)
  out.post = b.post
  out.deferred = deferred_copy(b.deferred)
  deferred_append(out.deferred, tail)
  return out
end

local function combine_seq_at_path(a, b, path, tail)
  if path == nil or #path == 0 then return combine_seq(a, b, tail) end
  local vals = structural_clone(a.vals)
  local out = new(vals, a.role or b.role)
  if not merge_common(a, b, out) then return nil end
  Resource.merge_seq_into(out, b)
  out.post = compose_slot_post(a.post, path, b.post)
  if not set_target_pack(out, path, b.vals) then return nil end
  out.deferred = deferred_copy(a.deferred)
  deferred_append(out.deferred, b.deferred, path[1] and path)
  deferred_append(out.deferred, tail)
  return out
end

local function combine_parallel(a, b, lane_index)
  local out = new(pack_(), a.role or b.role)
  if not merge_common(a, b, out) then return nil end
  local ok = Resource.merge_parallel_into(out, b)
  if not ok then return nil end
  out.post = nil
  out.deferred = deferred_copy(a.deferred)
  deferred_append(out.deferred, b.deferred, lane_index)
  return out
end

Candidate.list_append = list_append
Candidate.list_copy = list_copy
Candidate.unique_append = unique_append
Candidate.new_ph = new_ph
Candidate.is_ph = is_ph
Candidate.is_structural_value = is_structural_value
Candidate.is_opaque_value = is_opaque_value
Candidate.subst_bind = subst_bind
Candidate.subst_copy = subst_copy
Candidate.subst_merge = subst_merge
Candidate.raw_resolved = raw_resolved
Candidate.resolve = resolve
Candidate.structural_clone = structural_clone
Candidate.same_path = same_path
Candidate.deferred_copy = deferred_copy
Candidate.deferred_append = deferred_append
Candidate.target_pack = target_pack
Candidate.set_target_pack = set_target_pack
Candidate.deferred_target_resolved = deferred_target_resolved
Candidate.deferred_target_values = deferred_target_values
Candidate.compose_slot_post = compose_slot_post
Candidate.resolve_pack = resolve_pack
Candidate.new = new
Candidate.empty = empty
Candidate.clone = clone
Candidate.add_effect = add_effect
Candidate.merge_effect_combo = merge_effect_combo
Candidate.effects_compatible = effects_compatible
Candidate.overlay_from = overlay_from
Candidate.ctx_with_overlay = ctx_with_overlay
Candidate.combine_seq = combine_seq
Candidate.combine_seq_at_path = combine_seq_at_path
Candidate.combine_parallel = combine_parallel

return Candidate
