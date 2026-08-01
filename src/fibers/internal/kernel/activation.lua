-- Interned execution identity, product provenance and activation-local memoisation.

local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Operation = require('fibers.internal.operation')

local M = {}
local unpack_ = table.unpack or unpack
local EMPTY_INPUT = { n = 0 }

local function node(context, parent)
  context.next_id = context.next_id + 1
  return { context = context, id = context.next_id, parent = parent, depth = parent and parent.depth + 1 or 0 }
end

function M.new_request(request_order)
  return node({ request_order = request_order, next_id = 0, guards = {}, clocks = {} })
end

local CHILD = {}

local function finish(parent, children)
  local child = children[CHILD]
  if not child then
    child = node(parent.context, parent)
    children[CHILD] = child
  end
  return child
end

function M.child(parent, ...)
  if not parent then
    error('activation child requires a parent token', 2)
  end
  local count = select('#', ...)
  if count == 0 then
    error('activation fact is required', 2)
  end
  local children = parent.children
  if not children then
    children = {}
    parent.children = children
  end
  for i = 1, count do
    local key = select(i, ...)
    if key == nil then
      error('activation fact is required', 2)
    end
    local next_branch = children[key]
    if not next_branch then
      next_branch = {}
      children[key] = next_branch
    end
    children = next_branch
  end
  return finish(parent, children)
end

function M.child_array(parent, head, values)
  if not parent or head == nil then
    error('activation fact is required', 2)
  end
  local children = parent.children
  if not children then
    children = {}
    parent.children = children
  end
  local next_branch = children[head]
  if not next_branch then
    next_branch = {}
    children[head] = next_branch
  end
  children = next_branch
  for i = 1, #(values or {}) do
    local key = values[i]
    local branch = children[key]
    if not branch then
      branch = {}
      children[key] = branch
    end
    children = branch
  end
  return finish(parent, children)
end

function M.less(left, right)
  local a, b = left.context, right.context
  if a.request_order ~= b.request_order then
    return a.request_order < b.request_order
  end
  return left.id < right.id
end

function M.scope_child(parent, group, mode, lane)
  return { parent = parent, depth = parent and parent.depth + 1 or 1, group = group, mode = mode, lane = lane }
end

local function provenance_relation(left, right)
  if left == right then
    return 'same'
  end
  local a, b = left, right
  local da, db = a and a.depth or 0, b and b.depth or 0
  while da > db do
    a, da = a.parent, da - 1
  end
  while db > da do
    b, db = b.parent, db - 1
  end
  if a == b then
    return left and left.depth > (right and right.depth or 0) and 'ancestor' or 'descendant'
  end
  while a and b and a.parent ~= b.parent do
    a, b = a.parent, b.parent
  end
  if not a or not b or a.group ~= b.group or a.lane == b.lane then
    return 'unrelated'
  end
  return a.mode == 'interacting' and 'interacting' or 'independent'
end

function M.relation(root, path, other_root, other_path)
  if root ~= other_root then
    return 'external'
  end
  return provenance_relation(path, other_path)
end

local function normalise(input)
  if input == nil or (input.n or #input) == 0 then
    return EMPTY_INPUT
  end
  return input
end

local function cached(activation, input_pack)
  local entries = activation.context.guards[activation]
  if not entries then
    return nil
  end
  local input = normalise(input_pack)
  for i = 1, #entries do
    local entry = entries[i]
    if Values.equal(entry.input, input) then
      return entry.residual
    end
  end
end

local function refine(request, metadata)
  if not request or not metadata or request.metadata == metadata then
    return false
  end
  request.metadata = metadata
  return true
end

function M.clock(runtime, _request, occurrence, activation)
  local clocks = activation.context.clocks
  local by_activation = clocks[activation]
  if not by_activation then
    by_activation = {}
    clocks[activation] = by_activation
  end
  local entry = by_activation[occurrence]
  if entry ~= nil then
    return entry
  end
  local value = runtime.runtime:now()
  by_activation[occurrence] = value
  return value
end

function M.guard(runtime, request, guard, activation, reveal, input_pack)
  if not request or not activation then
    return nil, false
  end
  local input = normalise(input_pack)
  local residual = cached(activation, input)
  if residual or not reveal then
    return residual, false
  end

  residual =
    runtime.runtime:_call_in_phase('guard', 'callback_error', guard.fn, unpack_(input, 1, input.n or #input))
  if not Op.is_op(residual) then
    error('guard callback must return an Op', 0)
  end

  local guards = activation.context.guards
  local entries = guards[activation]
  if not entries then
    entries = {}
    guards[activation] = entries
  end
  entries[#entries + 1] = { input = input, residual = residual }

  if request.op == guard and activation == request.activation_root then
    refine(request, Operation.shape(residual))
  end
  return residual, true
end

return M
