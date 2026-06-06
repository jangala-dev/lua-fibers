-- Compact external transaction algebra for texlua.
-- Operations are immutable syntax nodes; Runtime supplies the solver.

local Op = {}
Op.__index = Op

local unpack_ = table.unpack or unpack
local next_op_id = 0

local function pack_(...)
  return { n = select('#', ...), ... }
end

local function op(kind, fields)
  next_op_id = next_op_id + 1
  local t = fields or {}
  t.kind = kind
  t._id = next_op_id
  return setmetatable(t, Op)
end

local function contains_wrap(x)
  if not x then return false end
  if x._contains_wrap ~= nil then return x._contains_wrap end

  local found = false
  if x.kind == 'wrap' then
    found = true
  elseif x.kind == 'map' or x.kind == 'bind' then
    found = contains_wrap(x.p)
  elseif x.kind == 'or_else' then
    found = contains_wrap(x.p) or contains_wrap(x.q)
  elseif x.kind == 'all' or x.kind == 'tensor' then
    for i = 1, #(x.lanes or {}) do
      if contains_wrap(x.lanes[i]) then found = true; break end
    end
  elseif x.kind == 'choice' then
    for i = 1, #(x.choices or {}) do
      if contains_wrap(x.choices[i]) then found = true; break end
    end
  end

  x._contains_wrap = found
  return found
end

local function assert_not_wrapped(self, name)
  if contains_wrap(self) then
    error(name .. ' cannot be applied after wrap: wrap is a post-commit boundary', 2)
  end
end

function Op.always(...)
  return op('always', { vals = pack_(...) })
end

function Op.never()
  return op('never')
end

function Op.emit(item)
  return op('emit', { item = item })
end

function Op.guard(fn)
  return op('guard', { fn = fn })
end

function Op.with_nack(fn)
  return op('with_nack', { fn = fn })
end

function Op._nack(ref)
  return op('nack', { ref = ref })
end

function Op.choice(...)
  local xs = { ... }
  return op('choice', { choices = xs })
end

function Op.all(xs)
  return op('all', { lanes = xs })
end

function Op.tensor(xs)
  return op('tensor', { lanes = xs })
end

function Op:map(fn)
  assert_not_wrapped(self, 'map')
  return op('map', { p = self, fn = fn })
end

function Op:and_then(fn)
  assert_not_wrapped(self, 'and_then')
  return op('bind', { p = self, fn = fn })
end

function Op:or_else(q)
  return op('or_else', { p = self, q = q })
end

function Op:wrap(fn)
  return op('wrap', { p = self, fn = fn, _contains_wrap = true })
end

-- Primitive constructor used by resources.
function Op._resource(resource, kind, payload)
  return op('prim', { prim = 'resource', resource = resource, resource_kind = kind, payload = payload })
end

Op._pack = pack_
Op._unpack = unpack_

return Op
