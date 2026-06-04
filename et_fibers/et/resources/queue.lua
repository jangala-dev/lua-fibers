local Protocol = require('et.protocol')

local Effect = Protocol.Effect

local next_id = 0

local function copy_items(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function same_items(a, b)
  a = a or {}; b = b or {}
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function fragment_from(snap, items, written)
  return {
    base_version = snap.version,
    base_items = copy_items(snap.items or {}),
    items = copy_items(items or snap.items or {}),
    written = written and true or false,
  }
end

local function copy_fragment(fragment)
  return {
    base_version = fragment.base_version,
    base_items = copy_items(fragment.base_items or {}),
    items = copy_items(fragment.items or {}),
    written = fragment.written and true or false,
  }
end

local function ensure_fresh(resource, snap, fragment, what, ctx)
  if fragment.base_version ~= snap.version then
    return ctx:stale({ resource }, (what or 'queue fragment') .. ' base version does not match view')
  end
  return nil
end

local function project_fragment(resource, snap, base, full, ctx)
  local stale = ensure_fresh(resource, snap, base, 'queue project base', ctx) or ensure_fresh(resource, snap, full, 'queue project full', ctx)
  if stale then return stale end
  if same_items(base.items, full.items) then return nil end
  return copy_fragment(full)
end

local function extend_fragment(resource, snap, prefix, delta, ctx)
  if delta == nil then return copy_fragment(prefix) end
  local stale = ensure_fresh(resource, snap, prefix, 'queue merge prefix', ctx) or ensure_fresh(resource, snap, delta, 'queue merge delta', ctx)
  if stale then return stale end
  if delta.written then return copy_fragment(delta) end
  return copy_fragment(prefix)
end

local function join(resource, snap, left, right, ctx)
  if left == nil then return copy_fragment(right) end
  if right == nil then return copy_fragment(left) end
  local stale = ensure_fresh(resource, snap, left, 'queue merge left', ctx) or ensure_fresh(resource, snap, right, 'queue merge right', ctx)
  if stale then return stale end
  if not left.written then return copy_fragment(right) end
  if not right.written then return copy_fragment(left) end
  if same_items(left.items, right.items) then return copy_fragment(left) end
  return ctx:conflict('conflicting parallel queue edits', resource)
end

local Queue = Protocol.Link.resource {
  name = 'queue',

  construct = function(self, items, label)
    next_id = next_id + 1
    self.id = 'queue-' .. tostring(next_id)
    self.label = label or ('queue-' .. tostring(next_id))
    self.items = copy_items(items or {})
    self.version = 0
  end,

  snapshot = function(self)
    return {
      resource = self,
      version = self.version,
      items = copy_items(self.items),
    }
  end,

  initial = function(_self, snap)
    return fragment_from(snap, snap.items, false)
  end,

  claim = function(self, snap, fragment, claim, ctx)
    local kind = claim.kind or 'access'
    local request = claim.request or claim.payload or claim or { tag = 'pop' }
    local tag = request.tag or request[1]

    if kind == 'await' then
      if tag ~= 'nonempty' then return ctx:fatal('unknown queue await claim ' .. tostring(tag)) end
      if #(snap.items or {}) > 0 then return ctx:ready(true) end
      return ctx:pending_on_self('queue empty')
    end

    if kind ~= 'access' then return ctx:fatal('unknown queue claim kind ' .. tostring(kind)) end

    local stale = ensure_fresh(self, snap, fragment, 'queue claim', ctx)
    if stale then return stale end

    local items = copy_items(fragment.items)

    if tag == 'push' then
      items[#items + 1] = request.value
      return ctx:accept(fragment_from(snap, items, true), true)
    elseif tag == 'pop' then
      if #items == 0 then return ctx:absent('queue empty') end
      local value = table.remove(items, 1)
      return ctx:accept(fragment_from(snap, items, true), value)
    elseif tag == 'peek' then
      if #items == 0 then return ctx:absent('queue empty') end
      return ctx:accept(copy_fragment(fragment), items[1])
    elseif tag == 'length' or tag == 'size' then
      return ctx:accept(copy_fragment(fragment), #items)
    elseif tag == 'clear' then
      return ctx:accept(fragment_from(snap, {}, true), true)
    end

    return ctx:fatal('unknown queue request ' .. tostring(tag))
  end,

  merge = function(self, snap, request, ctx)
    local kind = (request or {}).kind or 'coexist'
    local base = request and request.base or nil
    local fragments = request and request.fragments or {}

    if kind == 'project' then
      return project_fragment(self, snap, base, fragments[1], ctx)
    elseif kind == 'extend' then
      local acc = base
      for i = 1, #fragments do
        local r = extend_fragment(self, snap, acc, fragments[i], ctx)
        if r and r.tag then return r end
        acc = r
      end
      return acc
    end

    local acc = nil
    for i = 1, #fragments do
      acc = join(self, snap, acc, fragments[i], ctx)
      if acc and acc.tag then return acc end
    end
    return acc
  end,

  prepare = function(self, fragment, ctx)
    if fragment.base_version ~= self.version then
      return ctx:stale({ self }, 'queue fragment base version does not match current version')
    end
    local final_items = copy_items(fragment.items)
    local written = fragment.written and not same_items(self.items, final_items)
    local consequences = { transaction = {}, resource = {}, obligation = {} }
    if written and #self.items == 0 and #final_items > 0 then
      consequences.resource[#consequences.resource + 1] = Effect.wake(self.id .. '/nonempty', {
        resource = self,
        reason = 'queue-nonempty',
      })
    end
    return ctx:prepared({
      resource = self,
      fragment = copy_fragment(fragment),
      dirty = written and { self } or {},
      consequences = consequences,
      final_items = final_items,
      written = written,
    })
  end,

  commit = function(self, prepared)
    if prepared.written then
      self.items = copy_items(prepared.final_items)
      self.version = self.version + 1
    end
  end,
}

function Queue.is(x)
  return type(x) == 'table' and x.__et_resource == true and x.link_name == 'queue'
end

function Queue.assert(x, where)
  if not Queue.is(x) then error((where or 'queue') .. ': expected Queue', 3) end
  return x
end

function Queue:to_table()
  return copy_items(self.items)
end

function Queue:length()
  return #self.items
end

function Queue:push_op(Op, value)
  return Op.access(self, { tag = 'push', value = value })
end

function Queue:pop_op(Op)
  return Op.access(self, { tag = 'pop' })
end

function Queue:peek_op(Op)
  return Op.access(self, { tag = 'peek' })
end

function Queue:length_op(Op)
  return Op.access(self, { tag = 'length' })
end

function Queue:clear_op(Op)
  return Op.access(self, { tag = 'clear' })
end

function Queue:await_nonempty_op(Op)
  return Op.await(self, { tag = 'nonempty' })
end

function Queue:pop_wait_op(Op)
  local q = self
  return q:await_nonempty_op(Op):and_then(function()
    return q:pop_op(Op)
  end)
end

function Queue:force_push(value)
  self.items[#self.items + 1] = value
  self.version = self.version + 1
end

return Queue
