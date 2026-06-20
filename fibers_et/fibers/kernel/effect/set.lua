-- Mergeable effect sets for candidate worlds.

local Kind = require('fibers.kernel.effect.kind')

local EffectSet = {}
EffectSet.__index = EffectSet

local function key_string(kind, payload)
  local k = kind.key(payload)
  return tostring(kind._fibers_kind_id or kind.name) .. '\0' .. tostring(k)
end

function EffectSet.empty()
  return setmetatable({ entries = {}, order = {} }, EffectSet)
end

function EffectSet.is_set(x)
  return type(x) == 'table' and getmetatable(x) == EffectSet
end

function EffectSet:copy()
  local out = EffectSet.empty()
  for i = 1, #self.order do
    local k = self.order[i]
    out.order[i] = k
    out.entries[k] = self.entries[k]
  end
  return out
end

function EffectSet:is_empty()
  return #self.order == 0
end

function EffectSet:add(effect)
  if not Kind.is_effect(effect) then
    return nil, { kind = 'invalid_effect', message = 'expected typed effect obligation' }
  end

  local kind = effect.kind
  local k = key_string(kind, effect.payload)
  local existing = self.entries[k]

  if not existing then
    self.entries[k] = effect
    self.order[#self.order + 1] = k
    return self
  end

  local merged_payload, err = kind.merge(existing.payload, effect.payload)
  if not merged_payload then return nil, err or { kind = 'effect_conflict', message = kind.name .. ' merge conflict' } end

  self.entries[k] = {
    _fibers_effect = true,
    kind = kind,
    payload = merged_payload,
  }

  return self
end

function EffectSet:merge(other)
  if not other or other:is_empty() then return self end
  for i = 1, #other.order do
    local ok, err = self:add(other.entries[other.order[i]])
    if not ok then return nil, err end
  end
  return self
end

function EffectSet:items()
  local out = {}
  for i = 1, #self.order do
    local effect = self.entries[self.order[i]]
    out[#out + 1] = effect
  end
  table.sort(out, function(a, b)
    local ao, bo = a.kind.order or 1000, b.kind.order or 1000
    if ao ~= bo then return ao < bo end
    return (a.kind.name or '') < (b.kind.name or '')
  end)
  return out
end

function EffectSet:prepare(rt)
  local prepared = {}
  local xs = self:items()
  for i = 1, #xs do
    local effect = xs[i]
    local p, err = effect.kind.prepare(rt, effect.payload)
    if not p then return nil, err or { kind = 'effect_prepare_refused', message = effect.kind.name .. ' prepare refused' } end

    p.kind = p.kind or effect.kind
    p.kind_name = p.kind_name or effect.kind.name
    p.key = p.key
    if p.key == nil then p.key = effect.kind.key(effect.payload) end
    p.order = p.order or effect.kind.order or 1000
    p.payload = p.payload or effect.payload
    if type(p.discharge) ~= 'function' then
      return nil, { kind = 'invalid_prepared_effect', message = effect.kind.name .. ' prepare must return discharge function' }
    end
    prepared[#prepared + 1] = p
  end
  return prepared
end

return EffectSet
