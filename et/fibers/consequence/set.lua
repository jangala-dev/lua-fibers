-- Mergeable consequence sets for candidate worlds.

local Kind = require('fibers.consequence.kind')

local ConsequenceSet = {}
ConsequenceSet.__index = ConsequenceSet

local function key_string(kind, payload)
  local k = kind.key(payload)
  return tostring(kind._fibers_kind_id or kind.name) .. '\0' .. tostring(k)
end

function ConsequenceSet.empty()
  return setmetatable({ entries = {}, order = {} }, ConsequenceSet)
end

function ConsequenceSet.is_set(x)
  return type(x) == 'table' and getmetatable(x) == ConsequenceSet
end

function ConsequenceSet:copy()
  local out = ConsequenceSet.empty()
  for i = 1, #self.order do
    local k = self.order[i]
    out.order[i] = k
    out.entries[k] = self.entries[k]
  end
  return out
end

function ConsequenceSet:is_empty()
  return #self.order == 0
end

function ConsequenceSet:add(consequence)
  if not Kind.is_consequence(consequence) then
    return nil, { kind = 'invalid_consequence', message = 'expected typed consequence obligation' }
  end

  local kind = consequence.kind
  local k = key_string(kind, consequence.payload)
  local existing = self.entries[k]

  if not existing then
    self.entries[k] = consequence
    self.order[#self.order + 1] = k
    return self
  end

  local merged_payload, err = kind.merge(existing.payload, consequence.payload)
  if not merged_payload then return nil, err or { kind = 'consequence_conflict', message = kind.name .. ' merge conflict' } end

  self.entries[k] = {
    _fibers_consequence = true,
    kind = kind,
    payload = merged_payload,
  }

  return self
end

function ConsequenceSet:merge(other)
  if not other or other:is_empty() then return self end
  for i = 1, #other.order do
    local ok, err = self:add(other.entries[other.order[i]])
    if not ok then return nil, err end
  end
  return self
end

function ConsequenceSet:items()
  local out = {}
  for i = 1, #self.order do
    local c = self.entries[self.order[i]]
    out[#out + 1] = c
  end
  table.sort(out, function(a, b)
    local ao, bo = a.kind.order or 1000, b.kind.order or 1000
    if ao ~= bo then return ao < bo end
    return (a.kind.name or '') < (b.kind.name or '')
  end)
  return out
end

function ConsequenceSet:prepare(rt)
  local prepared = {}
  local xs = self:items()
  for i = 1, #xs do
    local c = xs[i]
    local p, err = c.kind.prepare(rt, c.payload)
    if not p then return nil, err or { kind = 'consequence_prepare_refused', message = c.kind.name .. ' prepare refused' } end

    p.kind = p.kind or c.kind
    p.kind_name = p.kind_name or c.kind.name
    p.key = p.key
    if p.key == nil then p.key = c.kind.key(c.payload) end
    p.order = p.order or c.kind.order or 1000
    p.payload = p.payload or c.payload
    if type(p.publish) ~= 'function' then
      return nil, { kind = 'invalid_prepared_consequence', message = c.kind.name .. ' prepare must return publish function' }
    end
    prepared[#prepared + 1] = p
  end
  return prepared
end

return ConsequenceSet
