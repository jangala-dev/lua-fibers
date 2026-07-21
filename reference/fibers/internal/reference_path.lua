-- Request-local semantic activation paths.
--
-- Op values are immutable and reusable.  An activation token identifies one
-- dynamic speculative progression through an option during a perform
-- attempt.  Tokens are interned beneath a request root, so reconstructing the
-- same structural/proof path recovers the same token while a different path
-- receives a distinct token.  The tree is monotonic and deliberately lives
-- outside speculative rollback.

local M = {}

local function new_token(context)
  context.next_id = context.next_id + 1
  return {
    context = context,
    id = context.next_id,
  }
end

function M.new_request(request_id)
  local context = {
    request_id = request_id,
    next_id = 0,
  }
  local root = new_token(context)
  return root
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
  if child then
    return child
  end
  child = new_token(parent.context)
  children[fact] = child
  return child
end

function M.label(token)
  if not token then
    return '-'
  end
  local label = token.label
  if not label then
    label = tostring(token.context.request_id) .. ':' .. tostring(token.id)
    token.label = label
  end
  return label
end

return M
