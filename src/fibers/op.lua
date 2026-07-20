-- Compact external transaction algebra for lua.
-- Options are immutable syntax nodes; Runtime supplies the solver.
--
-- The canonical search grammar is deliberately small:
--   always | primitive | choose | and_then | product | or_else | consequence
-- Post-commit value transforms and typed defeat obligations are orthogonal
-- annotations on dynamic option occurrences.

local EffectKind = require('fibers.lifetime.effect_kind')

local Op = {}
Op.__index = Op

local unpack_ = table.unpack or unpack
local next_op_id = 0

local EMPTY_PACK = { _fibers_pack = true, n = 0 }
local function pack_(...)
  local n = select('#', ...)
  if n == 0 then
    return EMPTY_PACK
  end
  return { _fibers_pack = true, n = n, ... }
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
  if type(x) ~= 'table' then
    return false
  end
  local n = #x
  for k in pairs(x) do
    if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then
      return false
    end
  end
  return true
end

local function append_choice_arg(out, x, level)
  level = level or 2
  if is_op(x) then
    if x.kind == 'choice' then
      for i = 1, #(x.choices or {}) do
        out[#out + 1] = x.choices[i]
      end
    else
      out[#out + 1] = x
    end
    return
  end
  if type(x) == 'table' then
    if not is_dense_array(x) then
      error('choice expects Op values or dense arrays of Op values', level)
    end
    for i = 1, #x do
      append_choice_arg(out, x[i], level + 1)
    end
    return
  end
  error('choice expects Op values or dense arrays of Op values', level)
end

local function parse_named_entries(entries, label)
  if type(entries) ~= 'table' then
    error(label .. ' expects a table', 3)
  end
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
    if not is_op(v) then
      error(label .. ' expects a map of Op values', 3)
    end
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for i = 1, #keys do
    out[#out + 1] = { keys[i], entries[keys[i]] }
  end
  return out
end

local function empty_rows()
  return { _fibers_rows = true }
end

local function row_value(row)
  if type(row) == 'table' and row._fibers_pack and row.n == 1 then
    return row[1]
  end
  return row
end

local function contains_wrap(x)
  if not x then
    return false
  end
  if x._contains_wrap ~= nil then
    return x._contains_wrap
  end

  local found = false
  if x.kind == 'annotated' then
    found = x.post ~= nil or contains_wrap(x.p)
  elseif x.kind == 'and_then' then
    found = contains_wrap(x.p)
  elseif x.kind == 'or_else' then
    found = contains_wrap(x.p) or contains_wrap(x.q)
  elseif x.kind == 'product' then
    for i = 1, #(x.lanes or {}) do
      if contains_wrap(x.lanes[i]) then
        found = true
        break
      end
    end
  elseif x.kind == 'choice' then
    for i = 1, #(x.choices or {}) do
      if contains_wrap(x.choices[i]) then
        found = true
        break
      end
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

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function annotated(inner, post, defeat, symmetry_key)
  local base, existing_post, existing_symmetry, defeats
  if inner.kind == 'annotated' then
    base = inner.p
    existing_post = inner.post
    existing_symmetry = inner.symmetry_key
    defeats = copy_list(inner.defeats)
  else
    base = inner
    defeats = {}
  end

  if post and existing_post then
    local first, second = existing_post, post
    post = function(...)
      return second(first(...))
    end
  else
    post = post or existing_post
  end

  if symmetry_key ~= nil and existing_symmetry ~= nil and symmetry_key ~= existing_symmetry then
    error('an option occurrence may carry only one certified symmetry key', 3)
  end
  symmetry_key = symmetry_key ~= nil and symmetry_key or existing_symmetry
  if defeat then
    table.insert(defeats, 1, defeat)
  end
  return op('annotated', {
    p = base,
    post = post,
    defeats = #defeats > 0 and defeats or nil,
    symmetry_key = symmetry_key,
    _contains_wrap = post ~= nil or contains_wrap(base),
  })
end

local EMPTY_ALWAYS, TRUE_ALWAYS, FALSE_ALWAYS
function Op.always(...)
  local n = select('#', ...)
  if n == 0 then
    if not EMPTY_ALWAYS then
      EMPTY_ALWAYS = op('always', { vals = EMPTY_PACK })
    end
    return EMPTY_ALWAYS
  end
  if n == 1 then
    local value = ...
    if value == true then
      if not TRUE_ALWAYS then
        TRUE_ALWAYS = op('always', { vals = pack_(true) })
      end
      return TRUE_ALWAYS
    elseif value == false then
      if not FALSE_ALWAYS then
        FALSE_ALWAYS = op('always', { vals = pack_(false) })
      end
      return FALSE_ALWAYS
    end
  end
  return op('always', { vals = pack_(...) })
end

function Op.never()
  return op('choice', { choices = {} })
end

function Op.emit(effect)
  if not EffectKind.is_effect(effect) then
    error('emit expects a typed effect obligation', 2)
  end
  return op('consequence', { effect = effect })
end


function Op.dependencies(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if value ~= nil then
      parts[#parts + 1] = value
    end
  end
  return { _fibers_dependencies = true, parts = parts }
end

local function continuation_hint(opts)
  if opts == nil or opts == false then
    return opts
  end
  if is_op(opts) then
    return opts
  end
  if type(opts) ~= 'table' then
    error('continuation metadata must be an Op or a footprint table', 3)
  end
  return opts.footprint or opts.continuation or opts
end

-- Delayed construction is derived through and_then.  The evaluator memoises
-- each guard by its request-local speculative activation, rather than by Op
-- object identity.
function Op.guard(fn, opts)
  return op('and_then', {
    p = Op.always(),
    fn = fn,
    callback_phase = 'guard',
    continuation_footprint = continuation_hint(opts),
  })
end

-- A typed defeat obligation is discharged if this option occurrence is
-- entered as a competing branch and another incompatible branch commits.
-- Retry, fallback and incomplete search are not defeat.
function Op:on_defeat(effect)
  if not EffectKind.is_effect(effect) then
    error('on_defeat expects a typed Effect', 2)
  end
  return annotated(self, nil, effect, nil)
end

function Op.choice(...)
  local xs = {}
  for i = 1, select('#', ...) do
    append_choice_arg(xs, select(i, ...), 2)
  end
  if #xs == 0 then
    return Op.never()
  end
  if #xs == 1 then
    return xs[1]
  end
  return op('choice', { choices = xs })
end

function Op.named_choice(entries)
  local parsed = parse_named_entries(entries, 'named_choice')
  local branches = {}
  for i = 1, #parsed do
    local name, branch = parsed[i][1], parsed[i][2]
    branches[i] = branch:map(function(...)
      return name, ...
    end)
  end
  return Op.choice(branches)
end

local function product(xs, mode, label)
  if type(xs) ~= 'table' then
    error(label .. ' expects an array of Op values', 3)
  end
  if #xs == 0 then
    return Op.always(empty_rows())
  end
  return op('product', { lanes = xs, mode = mode })
end

function Op.all(xs)
  return product(xs, 'independent', 'all')
end

function Op.named_all(entries)
  local parsed = parse_named_entries(entries, 'named_all')
  local lanes = {}
  for i = 1, #parsed do
    lanes[i] = parsed[i][2]
  end
  return Op.all(lanes):map(function(rows)
    local out = {}
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
  return product(xs, 'interacting', 'tensor')
end

function Op:map(fn)
  assert_not_wrapped(self, 'map')
  -- Canonically and_then followed by always. Retaining the original callback as
  -- metadata lets the interpreter fuse that derived always without adding a
  -- separate grammar node or allocation.
  return op('and_then', {
    p = self,
    callback_phase = 'map',
    fn = fn,
    derived_map = true,
    continuation_footprint = false,
  })
end

function Op:and_then(fn, opts)
  assert_not_wrapped(self, 'and_then')
  return op('and_then', {
    p = self,
    fn = fn,
    callback_phase = 'and_then',
    continuation_footprint = continuation_hint(opts),
  })
end

function Op:or_else(q)
  return op('or_else', { p = self, q = q })
end

function Op:wrap(fn)
  return annotated(self, fn, nil, nil)
end

-- Explicitly certify that pending occurrences carrying the same key are
-- observationally interchangeable for search.  The certificate covers the
-- complete option occurrence, including the fibre continuation after it
-- commits; the solver never infers this property automatically.
function Op:certify_symmetry(key)
  if key == nil then
    error('certify_symmetry expects a non-nil key', 2)
  end
  return annotated(self, nil, nil, key)
end

function Op._symmetry_key(value)
  return is_op(value) and value.kind == 'annotated' and value.symmetry_key or nil
end

-- Compact trusted primitive used by high-frequency facilities.  The option
-- node itself carries the immutable programme fields, avoiding a second table
-- between the option and the evaluator.  General facilities may continue to
-- use _resource with a separate IR programme record.
function Op._compact_resource(resource, kind, program_kind, fields)
  fields = fields or {}
  fields.primitive = 'resource'
  fields.resource = resource
  fields.resource_kind = kind
  fields.program_kind = program_kind
  fields._fibers_program = true
  local compact = op('primitive', fields)
  compact.program = compact
  return compact
end

-- Shared immutable programme descriptor for value-bearing compact
-- primitives.  Each dynamic occurrence then carries only this descriptor and
-- its payload; dependency metadata is cached on the descriptor rather than on
-- every occurrence.
function Op._compact_descriptor(resource, kind, program_kind, fields)
  fields = fields or {}
  fields.primitive = 'resource'
  fields.resource = resource
  fields.resource_kind = kind
  fields.program_kind = program_kind
  fields._fibers_program = true
  fields._fibers_compact_descriptor = true
  return fields
end

function Op._compact_occurrence(descriptor, payload)
  if not (descriptor and descriptor._fibers_compact_descriptor) then
    error('compact occurrence requires a compact descriptor', 2)
  end
  return op('primitive', { program = descriptor, payload = payload })
end

-- Primitive constructor used by trusted facilities.
function Op._resource(resource, kind, payload)
  return op('primitive', {
    primitive = 'resource',
    resource = resource,
    resource_kind = kind,
    payload = payload,
    program = payload,
  })
end

Op.is_op = is_op
Op._pack = pack_
Op._unpack = unpack_

return Op
