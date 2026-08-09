-- Interned execution identity, product provenance and activation-local memoisation.

local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Operation = require('fibers.internal.operation')

local M = {}
local unpack_ = table.unpack or unpack
local EMPTY_INPUT = Values.pack()

local function node(context, parent)
  context.next_id = context.next_id + 1
  return { context = context, id = context.next_id, parent = parent, depth = parent and parent.depth + 1 or 0 }
end

function M.new_request(request_order)
  return node({ request_order = request_order, next_id = 0 })
end

local CHILD = {}

local function children_of(parent)
  local children = parent.children
  if not children then
    children = {}
    parent.children = children
  end
  return children
end

local function descend(children, key)
  if key == nil then error('activation fact is required', 3) end
  local branch = children[key]
  if not branch then
    branch = {}
    children[key] = branch
  end
  return branch
end

local function finish(parent, children)
  local child = children[CHILD]
  if not child then
    child = node(parent.context, parent)
    children[CHILD] = child
  end
  return child
end

function M.child(parent, ...)
  if not parent then error('activation child requires a parent token', 2) end
  local count = select('#', ...)
  if count == 0 then error('activation fact is required', 2) end
  local children = children_of(parent)
  for i = 1, count do
    children = descend(children, select(i, ...))
  end
  return finish(parent, children)
end

function M.child_array(parent, head, values)
  if not parent or head == nil then error('activation fact is required', 2) end
  local children = descend(children_of(parent), head)
  for i = 1, #values do
    children = descend(children, values[i])
  end
  return finish(parent, children)
end

function M.less(left, right)
  local a, b = left.context, right.context
  if a.request_order ~= b.request_order then return a.request_order < b.request_order end
  return left.id < right.id
end

function M.scope_child(parent, group, mode, lane)
  return { parent = parent, depth = parent and parent.depth + 1 or 1, group = group, mode = mode, lane = lane }
end

local function provenance_relation(left, right)
  if left == right then return nil end
  local a, b = left, right
  local da, db = a and a.depth or 0, b and b.depth or 0
  while da > db do a, da = a.parent, da - 1 end
  while db > da do b, db = b.parent, db - 1 end
  if a == b then return nil end
  while a and b and a.parent ~= b.parent do a, b = a.parent, b.parent end
  if not a or not b or a.group ~= b.group or a.lane == b.lane then return nil end
  return a.mode == 'interacting' and 'interacting' or 'independent'
end

function M.relation(root, path, other_root, other_path)
  if root ~= other_root then return 'external' end
  return provenance_relation(path, other_path)
end

local function normalise(input)
  if input == nil or input.n == 0 then return EMPTY_INPUT end
  return input
end

local function cached(activation, input)
  for i = 1, #(activation.guards or {}) do
    local entry = activation.guards[i]
    if Values.equal(entry.input, input) then return entry.residual end
  end
end

function M.clock(engine, occurrence, activation)
  local clocks = activation.clocks
  if not clocks then
    clocks = {}
    activation.clocks = clocks
  end
  local entry = clocks[occurrence]
  if entry ~= nil then return entry end
  local value = engine.runtime:now()
  clocks[occurrence] = value
  return value
end

function M.guard(engine, request, guard, activation, input_pack)
  local input = normalise(input_pack)
  local residual = cached(activation, input)
  if residual then return residual end

  residual = engine.runtime:_call_in_phase('guard', 'callback_error', guard.fn, unpack_(input, 1, input.n))
  if not Op.is_op(residual) then error('guard callback must return an Op', 0) end

  local entries = activation.guards
  if not entries then
    entries = {}
    activation.guards = entries
  end
  entries[#entries + 1] = { input = input, residual = residual }

  if request.op == guard and activation == request.activation_root then
    request.metadata = Operation.shape(residual)
  end
  return residual
end

return M
