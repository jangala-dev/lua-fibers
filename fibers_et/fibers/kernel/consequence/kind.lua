-- Typed runtime obligations carried by committed candidate worlds.
--
-- A consequence kind owns the small algebra for one family of obligations:
-- construction, keying, duplicate merge, commit-time preparation and
-- post-resource publication.

local ConsequenceKind = {}
ConsequenceKind.__index = ConsequenceKind

local next_kind_id = 0

local function assert_field(spec, name, ty)
  if type(spec[name]) ~= ty then
    error('ConsequenceKind.new requires ' .. name .. ' :: ' .. ty, 3)
  end
end

function ConsequenceKind.new(spec)
  assert(type(spec) == 'table', 'ConsequenceKind.new expects a spec table')
  assert_field(spec, 'name', 'string')
  assert_field(spec, 'key', 'function')
  assert_field(spec, 'merge', 'function')
  assert_field(spec, 'prepare', 'function')

  next_kind_id = next_kind_id + 1
  local kind = {
    _fibers_consequence_kind = true,
    _fibers_kind_id = next_kind_id,
    name = spec.name,
    key = spec.key,
    merge = spec.merge,
    prepare = spec.prepare,
    order = spec.order or 1000,
    failure = spec.failure or 'fatal',
    validate_payload = spec.validate_payload,
  }

  if kind.failure ~= 'fatal' then
    error('unsupported consequence failure policy: ' .. tostring(kind.failure), 2)
  end

  return setmetatable(kind, ConsequenceKind)
end

function ConsequenceKind:of(payload)
  if type(payload) ~= 'table' then
    return nil, { kind = 'invalid_consequence_payload', message = self.name .. ' payload must be a table' }
  end

  if self.validate_payload then
    local ok, err = self.validate_payload(self, payload)
    if not ok then return nil, err end
  end

  return {
    _fibers_consequence = true,
    kind = self,
    payload = payload,
  }
end

function ConsequenceKind.is_kind(x)
  return type(x) == 'table' and x._fibers_consequence_kind == true
end

function ConsequenceKind.is_consequence(x)
  return type(x) == 'table' and x._fibers_consequence == true and ConsequenceKind.is_kind(x.kind)
end

return ConsequenceKind
