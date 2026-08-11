-- Public option language for Fibers. The kernel driver supplies proof search and commit.
--
-- Application code should read in ordinary terms:
--   choice       either coherent world is acceptable
--   and_then     sequence another operation in the same transaction
--   or_else      use the fallback only after valid present refutation
--   each         satisfy every lane, with each standing on its own
--   together     satisfy every lane, allowing compatible sibling support
--   wrap         continue in the participant after commitment
--
-- Options are inert, opaque library values: construct, combine and perform
-- them through this API. Their Lua table representation is not an API surface.
--
-- The canonical search grammar is deliberately small:
--   always | primitive | choice | guard | map | and_then | product | or_else | consequence
-- Post-commit value transforms and typed defeat obligations are orthogonal
-- annotations on dynamic option occurrences.

local function is_effect(value)
  return type(value) == 'table'
    and value._fibers_effect == true
    and type(value.kind) == 'table'
    and value.kind._fibers_effect_kind == true
end

local Values = require('fibers.internal.values')
local Operation = require('fibers.internal.operation')

local Op = Operation.class

local function op(kind, fields)
  return Operation.new(kind, fields)
end

local function is_op(value)
  return Operation.is(value)
end

local function is_dense_array(x)
  if type(x) ~= 'table' then
    return false
  end

  local count, highest = 0, 0
  for k in next, x do
    if type(k) ~= 'number' or k < 1 or k ~= math.floor(k) then
      return false
    end
    count = count + 1
    if k > highest then
      highest = k
    end
  end
  return highest == count
end

local function append_op_arg(out, value, label, flatten_choice, level)
  if is_op(value) then
    if flatten_choice and value.kind == 'choice' and not (value.post or value.defeats or value.labels) then
      for i = 1, #(value.choices or {}) do
        out[#out + 1] = value.choices[i]
      end
    else
      out[#out + 1] = value
    end
    return
  end
  if type(value) == 'table' then
    if not is_dense_array(value) then
      error(label .. ' expects Op values or dense arrays of Op values', level)
    end
    for i = 1, #value do
      append_op_arg(out, value[i], label, flatten_choice, level + 1)
    end
    return
  end
  error(label .. ' expects Op values or dense arrays of Op values', level)
end

local function parse_named_entries(entries, label)
  if type(entries) ~= 'table' then
    error(label .. ' expects a map of Op values', 3)
  end

  local keys = {}
  for key, value in pairs(entries) do
    if type(key) ~= 'string' or not is_op(value) then
      error(label .. ' expects a map from string names to Op values', 3)
    end
    keys[#keys + 1] = key
  end

  table.sort(keys)
  local out = {}
  for i = 1, #keys do
    local key = keys[i]
    out[i] = { key, entries[key] }
  end
  return out
end

local function empty_rows()
  return { _fibers_rows = true }
end

local function row_value(row)
  if Values.is(row) and row.n == 1 then
    return row[1]
  end
  return row
end

local function contains_wrap(value)
  return value ~= nil and value.has_wrap == true
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

local function annotated(inner, post, defeat, label)
  local fields = {}
  for key, value in pairs(inner) do fields[key] = value end

  local existing_post = fields.post
  if post and existing_post then
    local first, second = existing_post, post
    fields.post = function(...) return second(first(...)) end
  elseif post then
    fields.post = post
  end

  if defeat then
    local defeats = copy_list(fields.defeats)
    table.insert(defeats, 1, defeat)
    fields.defeats = defeats
  end
  if label then
    local labels = copy_list(fields.labels)
    table.insert(labels, 1, label)
    fields.labels = labels
  end
  return op(inner.kind, fields)
end

function Op.always(...)
  -- Return a fresh public option occurrence. Small shared singleton tables make
  -- unsupported mutation non-local and are not worth the minor allocation win.
  return op('always', { vals = Values.pack(...) })
end

function Op.never()
  return op('choice', { choices = {} })
end

function Op.emit(effect)
  if not is_effect(effect) then
    error('emit expects a typed effect obligation', 2)
  end
  return op('consequence', { effect = effect })
end

-- Delayed algebraic elaboration is a first-class node. The evaluator memoises
-- each guard by its request-local speculative activation and the provisional
-- values supplied by an immediately preceding and_then. The builder receives
-- those values directly as varargs and returns the explicit residual Op.
function Op.guard(fn)
  if type(fn) ~= 'function' then
    error('guard expects a function', 2)
  end
  return op('guard', { fn = fn })
end

-- A typed defeat obligation is discharged if this option occurrence is
-- entered as a competing branch and another incompatible branch commits.
-- Retry, fallback and incomplete search are not defeat.
function Op:on_defeat(effect)
  if not is_effect(effect) then
    error('on_defeat expects a typed Effect', 2)
  end
  return annotated(self, nil, effect)
end

-- Unordered permission: any coherent branch may commit. Source position does
-- not express priority; use or_else when a fallback requires proof that a
-- preferred world is presently absent.
function Op.choice(...)
  local xs = {}
  for i = 1, select('#', ...) do
    append_op_arg(xs, select(i, ...), 'choice', true, 2)
  end
  if #xs == 0 then
    return Op.never()
  end
  if #xs == 1 then
    return xs[1]
  end
  return op('choice', { choices = xs })
end

-- Choice with a result label. Useful when the branch names are already the
-- natural language of a mechanic: completed, skipped, player_left.
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

local function product(mode, label, ...)
  local lanes = {}
  for i = 1, select('#', ...) do
    append_op_arg(lanes, select(i, ...), label, false, 3)
  end

  if #lanes == 0 then
    return Op.always(empty_rows())
  end
  return op('product', { lanes = lanes, mode = mode })
end

-- Independent conjunction. Every lane must be supportable from the common
-- parent world; one sibling may constrain another but cannot supply it.
function Op.each(...)
  return product('independent', 'each', ...)
end

local function named_product(entries, label, constructor)
  local parsed = parse_named_entries(entries, label)
  local lanes = {}
  for i = 1, #parsed do
    lanes[i] = parsed[i][2]
  end
  return constructor(lanes):map(function(rows)
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

function Op.named_each(entries)
  return named_product(entries, 'named_each', Op.each)
end

-- Interacting conjunction. Compatible siblings may supply one another, such as
-- a scene cue written in one lane and read in another.
function Op.together(...)
  return product('interacting', 'together', ...)
end

function Op.named_together(entries)
  return named_product(entries, 'named_together', Op.together)
end

-- Transform provisional values during search. fn is pure, non-yielding and may
-- be replayed. Use wrap for participant-local work after commitment.
function Op:map(fn)
  if type(fn) ~= 'function' then
    error('map expects a function', 2)
  end
  assert_not_wrapped(self, 'map')
  return op('map', { p = self, fn = fn })
end

-- Continue transactionally with another operation. Earlier communication,
-- state and admission remain retractable until the complete sequence commits.
-- Use Op.guard when the right-hand operation depends on provisional values.
function Op:and_then(next_op)
  if not is_op(next_op) then
    error('and_then expects an Op; use Op.guard for a dynamic right-hand operation', 2)
  end
  assert_not_wrapped(self, 'and_then')
  return op('and_then', { p = self, q = next_op })
end

-- Proof-directed preference. The fallback is entered only after the preferred
-- option yields Retry; Unknown never grants permission to fall back.
function Op:or_else(q)
  if not is_op(q) then
    error('or_else expects an Op', 2)
  end
  return op('or_else', { p = self, q = q })
end

-- Resume participant-local code after commitment. Unlike speculative callbacks,
-- fn may perform further options and carry out ordinary application work.
function Op:wrap(fn)
  if type(fn) ~= 'function' then
    error('wrap expects a function', 2)
  end
  return annotated(self, fn, nil)
end

-- Attach semantically inert diagnostic metadata. Options are immutable values,
-- so labelling returns a fresh option and leaves the original unchanged.
function Op:label(value)
  if type(value) ~= 'string' or value == '' then
    error('Op:label expects a non-empty string', 2)
  end
  return annotated(self, nil, nil, value)
end

Op.is_op = is_op

return Op
