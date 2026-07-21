-- Interned semantic activation and persistent product provenance paths.

local M = {}

local function activation_node(context, parent)
  context.next_id = context.next_id + 1
  return {
    context = context,
    id = context.next_id,
    parent = parent,
    depth = parent and parent.depth + 1 or 0,
  }
end

function M.new_request(request_id)
  return activation_node({ request_id = request_id, next_id = 0 })
end

function M.child(parent, fact)
  if not parent then
    error('activation child requires a parent token', 2)
  end
  if type(fact) ~= 'string' then
    error('activation fact must be a string', 2)
  end
  local children = parent.children
  if not children then
    children = {}
    parent.children = children
  end
  local child = children[fact]
  if not child then
    child = activation_node(parent.context, parent)
    child.fact = fact
    children[fact] = child
  end
  return child
end

function M.label(path)
  if not path then
    return '-'
  end
  if not path.label then
    path.label = tostring(path.context.request_id) .. ':' .. tostring(path.id)
  end
  return path.label
end

function M.scope_child(parent, group_id, mode, lane)
  return {
    parent = parent,
    depth = parent and parent.depth + 1 or 1,
    group_id = group_id,
    mode = mode,
    lane = lane,
  }
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
  if not a or not b or a.group_id ~= b.group_id or a.lane == b.lane then
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

return M
