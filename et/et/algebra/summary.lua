-- Lazy static effect summaries for ET operation syntax.
-- These summaries are conservative: they are used only for pruning branches
-- that cannot affect the externally observable transaction algebra.

local Summary = {}

local function zero(may_commit)
  return {
    may_commit = may_commit ~= false,
    may_nack = false,
    dynamic = false,
    endpoints = false,
    resources = false,
    closed = may_commit ~= false,
  }
end

local function copy(a)
  return {
    may_commit = a.may_commit,
    may_nack = a.may_nack,
    dynamic = a.dynamic,
    endpoints = a.endpoints,
    resources = a.resources,
    closed = a.closed,
  }
end

local function union_into(a, b)
  a.may_commit = a.may_commit or b.may_commit
  a.may_nack = a.may_nack or b.may_nack
  a.dynamic = a.dynamic or b.dynamic
  a.endpoints = a.endpoints or b.endpoints
  a.resources = a.resources or b.resources
  a.closed = a.closed and b.closed
  return a
end

local function union_list(xs, first)
  local out = zero(false)
  out.closed = true
  if first then union_into(out, first) end
  for i = 1, #xs do union_into(out, Summary.of(xs[i])) end
  return out
end

function Summary.of(node)
  if not node then return zero(false) end
  if node._summary then return node._summary end
  local k = node.kind
  local s
  if k == 'always' or k == 'emit' then
    s = zero(true)
  elseif k == 'never' then
    s = zero(false)
  elseif k == 'prim' then
    s = zero(true)
    if node.prim == 'resource' then
      local kind = node.resource_kind
      if kind and kind.summary then kind.summary(node.payload, s) else s.dynamic = true; s.closed = false end
    else
      s.dynamic = true; s.closed = false
    end
  elseif k == 'map' or k == 'wrap' then
    s = copy(Summary.of(node.p))
  elseif k == 'bind' then
    s = copy(Summary.of(node.p))
    -- The continuation is value-dependent; be conservative.
    s.dynamic = true; s.closed = false
    s.may_nack = true
  elseif k == 'choice' then
    s = union_list(node.choices)
  elseif k == 'or_else' then
    s = union_list({ node.p, node.q })
  elseif k == 'all' or k == 'tensor' then
    s = union_list(node.lanes)
  elseif k == 'guard' or k == 'with_nack' then
    s = zero(true)
    s.dynamic = true; s.closed = false; s.may_nack = true
  elseif k == 'nack' then
    s = zero(true)
    s.dynamic = true; s.closed = false
  else
    s = zero(true)
    s.dynamic = true; s.closed = false; s.may_nack = true
  end
  node._summary = s
  return s
end

function Summary.decisive_without_resources(node)
  local s = Summary.of(node)
  return s.may_commit and s.closed and not s.dynamic and not s.endpoints and not s.resources
end

function Summary.may_nack(node)
  return Summary.of(node).may_nack
end

return Summary
