local Op = require('et.op')
local Resource = require('et.resources.protocol')
local ConsequenceSet = require('et.consequence.set')

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
    if x._nack_ref then return x end
    if seen and seen[x] then return x end
    seen = seen or {}; seen[x] = true
    local y = {}
    if x.n ~= nil then y.n = x.n end
    local n = x.n or #x
    for i = 1, n do y[i] = resolve(x[i], subst, seen) end
    return y
  else
    return x
  end
end

local function resolve_pack(p, subst)
  local q = { n = p.n or #p }
  for i = 1, q.n do q[i] = resolve(p[i], subst) end
  return q
end

local function new(vals, role)
  return {
    role = role or 'template',
    vals = vals or pack_(),
    deferred = {},
    endpoints = {},
    consequences = nil,
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
  local d = new(c.vals, 'search')
  d.subst = subst_copy(c.subst)
  d.deferred = list_copy(c.deferred)
  d.endpoints = {}
  for i = 1, #(c.endpoints or {}) do
    local e = c.endpoints[i]
    d.endpoints[i] = {
      kind = e.kind,
      primitive = e.primitive,
      role = e.role,
      key = e.key,
      origin = e.origin,
      ph = e.ph,
      value = e.value,
    }
  end
  d.consequences = c.consequences and c.consequences:copy() or nil
  d.post = c.post
  Resource.copy_from(d, c)
  d.selected_nacks = list_copy(c.selected_nacks)
  d.lost_nacks = list_copy(c.lost_nacks)
  d.protected_nacks = list_copy(c.protected_nacks)
  d.order = c.order
  d.fiber = c.fiber
  return d
end


local function add_consequence(c, consequence)
  local set = c.consequences
  if not set then
    set = ConsequenceSet.empty()
    c.consequences = set
  end
  return set:add(consequence)
end

local function merge_consequence_combo(combo)
  local set = nil
  for i = 1, #combo do
    local cs = combo[i].consequences
    if cs then
      set = set or ConsequenceSet.empty()
      local ok, err = set:merge(cs)
      if not ok then return nil, err or 'consequence-conflict' end
    end
  end
  return set
end

local function consequences_compatible(combo)
  local _set, err = merge_consequence_combo(combo)
  return err == nil, err
end

local function ctx_with_overlay(ctx, c)
  local n = {}
  for k, v in pairs(ctx) do n[k] = v end
  n.overlay = overlay_from(c, ctx.overlay)
  return n
end

local function merge_common(a, b, out)
  if a.consequences or b.consequences then
    local set = a.consequences and a.consequences:copy() or ConsequenceSet.empty()
    local ok, err = set:merge(b.consequences)
    if not ok then return false, err or 'consequence-conflict' end
    if not set:is_empty() then out.consequences = set end
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
  out.deferred = list_copy(b.deferred)
  list_append(out.deferred, tail)
  return out
end

local function combine_parallel(a, b)
  local out = new(pack_(), a.role or b.role)
  if not merge_common(a, b, out) then return nil end
  local ok = Resource.merge_parallel_into(out, b)
  if not ok then return nil end
  out.post = nil
  out.deferred = list_copy(a.deferred); list_append(out.deferred, b.deferred)
  return out
end

Candidate.list_append = list_append
Candidate.list_copy = list_copy
Candidate.unique_append = unique_append
Candidate.new_ph = new_ph
Candidate.is_ph = is_ph
Candidate.subst_bind = subst_bind
Candidate.subst_copy = subst_copy
Candidate.subst_merge = subst_merge
Candidate.raw_resolved = raw_resolved
Candidate.resolve = resolve
Candidate.resolve_pack = resolve_pack
Candidate.new = new
Candidate.empty = empty
Candidate.clone = clone
Candidate.add_consequence = add_consequence
Candidate.merge_consequence_combo = merge_consequence_combo
Candidate.consequences_compatible = consequences_compatible
Candidate.overlay_from = overlay_from
Candidate.ctx_with_overlay = ctx_with_overlay
Candidate.combine_seq = combine_seq
Candidate.combine_parallel = combine_parallel

return Candidate
