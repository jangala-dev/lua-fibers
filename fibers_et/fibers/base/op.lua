-- Compact external transaction algebra for texlua.
-- Operations are immutable syntax nodes; Runtime supplies the solver.

local EffectKind = require('fibers.kernel.effect.kind')

local Op = {}
Op.__index = Op

local unpack_ = table.unpack or unpack
local next_op_id = 0

local function pack_(...)
  return { _fibers_pack = true, n = select('#', ...), ... }
end

local function op(kind, fields)
  next_op_id = next_op_id + 1
  local t = fields or {}
  t.kind = kind
  t._id = next_op_id
  return setmetatable(t, Op)
end

local function is_op(x)
  return type(x) == 'table' and getmetatable(x) == Op
end

local function is_dense_array(x)
  if type(x) ~= 'table' then return false end
  local n = #x
  for k in pairs(x) do
    if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then return false end
  end
  return true
end

local function append_choice_arg(out, x, level)
  level = level or 2
  if is_op(x) then
    if x.kind == 'choice' then
      for i = 1, #(x.choices or {}) do out[#out + 1] = x.choices[i] end
    else
      out[#out + 1] = x
    end
    return
  end
  if type(x) == 'table' then
    if not is_dense_array(x) then error('choice expects Op values or dense arrays of Op values', level) end
    for i = 1, #x do append_choice_arg(out, x[i], level + 1) end
    return
  end
  error('choice expects Op values or dense arrays of Op values', level)
end

local function parse_named_entries(entries, label)
  if type(entries) ~= 'table' then error(label .. ' expects a table', 3) end
  local out = {}
  local n = #entries
  if n > 0 then
    for i = 1, n do
      local e = entries[i]
      if type(e) ~= 'table' or e[1] == nil or not is_op(e[2]) then
        error(label .. ' expects entries shaped { name, op }', 3)
      end
      out[#out + 1] = { e[1], e[2] }
    end
    for k in pairs(entries) do
      if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then
        error(label .. ' expects either ordered { name, op } entries or a map of Op values', 3)
      end
    end
    return out
  end

  local keys = {}
  for k, v in pairs(entries) do
    if not is_op(v) then error(label .. ' expects a map of Op values', 3) end
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for i = 1, #keys do out[#out + 1] = { keys[i], entries[keys[i]] } end
  return out
end

local function row_value(row)
  if type(row) == 'table' and row._fibers_pack and row.n == 1 then return row[1] end
  return row
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

function Op.emit(effect)
  if not EffectKind.is_effect(effect) then
    error('emit expects a typed effect obligation', 2)
  end
  return op('emit', { effect = effect })
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
  local xs = {}
  for i = 1, select('#', ...) do append_choice_arg(xs, select(i, ...), 2) end
  if #xs == 0 then return Op.never() end
  if #xs == 1 then return xs[1] end
  return op('choice', { choices = xs })
end

function Op.named_choice(entries)
  local parsed = parse_named_entries(entries, 'named_choice')
  local branches = {}
  for i = 1, #parsed do
    local name, branch = parsed[i][1], parsed[i][2]
    branches[i] = branch:map(function(...) return name, ... end)
  end
  return Op.choice(branches)
end

function Op.all(xs)
  if type(xs) ~= 'table' then error('all expects an array of Op values', 2) end
  return op('all', { lanes = xs })
end

function Op.named_all(entries)
  local parsed = parse_named_entries(entries, 'named_all')
  local lanes = {}
  for i = 1, #parsed do lanes[i] = parsed[i][2] end
  return Op.all(lanes):map(function(rows)
    local out = { _fibers_named_rows = true }
    local raw = {}
    out._rows = raw
    for i = 1, #parsed do
      local key = parsed[i][1]
      local row = rows[i]
      raw[key] = row
      out[key] = row_value(row)
    end
    return out
  end)
end

function Op.tensor(xs)
  if type(xs) ~= 'table' then error('tensor expects an array of Op values', 2) end
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

Op.is_op = is_op
Op._pack = pack_
Op._unpack = unpack_

return Op
