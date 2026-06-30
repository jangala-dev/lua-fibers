local Op = require('fibers.atoms.op')
local Resource = require('fibers.kernel.resources.protocol')
local EffectSet = require('fibers.kernel.effect.set')

local Proposal = {}
local pack_ = Op._pack
local next_ph = 0
local NIL = {}

local function list_copy(src)
  local dst = {}
  for i = 1, #(src or {}) do dst[i] = src[i] end
  return dst
end

local function new_ph()
  next_ph = next_ph + 1
  return { _ph = true, id = next_ph }
end

local function is_ph(x) return type(x) == 'table' and x._ph == true end

local function is_structural_value(x)
  return type(x) == 'table' and (x._fibers_pack == true or x._fibers_rows == true)
end

local function is_opaque_value(x)
  return type(x) == 'table' and not is_structural_value(x)
end

local function subst_lookup(subst, ph)
  if not subst then return false, nil end
  local v = subst[ph.id]
  if v == nil then return false, nil end
  if v == NIL then return true, nil end
  return true, v
end

local function subst_bind(p, ph, value)
  p.subst = p.subst or {}
  p.subst[ph.id] = (value == nil) and NIL or value
end

local function subst_copy(subst)
  if not subst then return nil end
  local out = {}
  for k, v in pairs(subst) do out[k] = v end
  return out
end

local function raw_resolved(x, subst, seen)
  if is_ph(x) then
    local ok, v = subst_lookup(subst, x)
    if ok then return raw_resolved(v, subst, seen) end
    return false
  elseif type(x) == 'table' then
    if is_opaque_value(x) or x._nack_ref then return true end
    if seen and seen[x] then return true end
    seen = seen or {}; seen[x] = true
    local n = x.n or #x
    for i = 1, n do if not raw_resolved(x[i], subst, seen) then return false end end
  end
  return true
end

local function resolve(x, subst, seen)
  if is_ph(x) then
    local ok, v = subst_lookup(subst, x)
    if ok then return resolve(v, subst, seen) end
    return x
  elseif type(x) == 'table' then
    if is_opaque_value(x) or x._nack_ref then return x end
    if seen and seen[x] then return x end
    seen = seen or {}; seen[x] = true
    local y = {}
    if x._fibers_pack then y._fibers_pack = true end
    if x._fibers_rows then y._fibers_rows = true end
    if x.n ~= nil then y.n = x.n end
    local n = x.n or #x
    for i = 1, n do y[i] = resolve(x[i], subst, seen) end
    return y
  end
  return x
end

local function resolve_pack(p, subst)
  if subst == nil then
    return p or pack_()
  end
  local q = { _fibers_pack = true, n = p and (p.n or #p) or 0 }
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

local function new(vals)
  return {
    vals = vals or pack_(),
    effects = nil,
    selected_nacks = {},
    lost_nacks = {},
    endpoints = {},
    res = nil,
    res_list = nil,
    subst = nil,
  }
end

local function clone(p)
  local q = new(structural_clone(p.vals))
  q.subst = subst_copy(p.subst)
  q.effects = p.effects and p.effects:copy() or nil
  q.selected_nacks = list_copy(p.selected_nacks)
  q.lost_nacks = list_copy(p.lost_nacks)
  Resource.copy_from(q, p)
  return q
end

local function add_effect(p, effect)
  p.effects = p.effects or EffectSet.empty()
  return p.effects:add(effect)
end

Proposal.new = new
Proposal.clone = clone
Proposal.new_ph = new_ph
Proposal.is_ph = is_ph
Proposal.raw_resolved = raw_resolved
Proposal.resolve = resolve
Proposal.resolve_pack = resolve_pack
Proposal.subst_bind = subst_bind
Proposal.subst_copy = subst_copy
Proposal.structural_clone = structural_clone
Proposal.add_effect = add_effect

return Proposal
