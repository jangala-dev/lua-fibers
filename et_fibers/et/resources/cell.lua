local Protocol = require('et.protocol')

local next_id = 0

local function copy_fragment(fragment)
  return {
    base_version = fragment.base_version,
    value = fragment.value,
    written = fragment.written,
  }
end

local function ensure_fresh(resource, snap, fragment, what, ctx)
  if fragment.base_version ~= snap.version then
    return ctx:stale({ resource }, (what or 'cell fragment') .. ' base version does not match view')
  end
  return nil
end

local function project_fragment(resource, snap, base, full, ctx)
  local stale = ensure_fresh(resource, snap, base, 'cell project base', ctx) or ensure_fresh(resource, snap, full, 'cell project full', ctx)
  if stale then return stale end
  if base.written == full.written and base.value == full.value then return nil end
  if full.written then
    return { base_version = snap.version, value = full.value, written = true }
  end
  return nil
end

local function extend_fragment(resource, snap, prefix, delta, ctx)
  if delta == nil then return copy_fragment(prefix) end
  local stale = ensure_fresh(resource, snap, prefix, 'cell merge prefix', ctx) or ensure_fresh(resource, snap, delta, 'cell merge delta', ctx)
  if stale then return stale end
  if delta.written then return copy_fragment(delta) end
  return copy_fragment(prefix)
end

local function join(resource, snap, left, right, ctx)
  if left == nil then return copy_fragment(right) end
  if right == nil then return copy_fragment(left) end
  local stale = ensure_fresh(resource, snap, left, 'cell merge left', ctx) or ensure_fresh(resource, snap, right, 'cell merge right', ctx)
  if stale then return stale end
  if not left.written then return copy_fragment(right) end
  if not right.written then return copy_fragment(left) end
  if left.value == right.value then return copy_fragment(left) end
  return ctx:conflict('conflicting cell writes', resource)
end

local Cell = Protocol.Link.resource {
  name = 'cell',

  construct = function(self, value, label)
    next_id = next_id + 1
    self.id = 'cell-' .. tostring(next_id)
    self.label = label or ('cell-' .. tostring(next_id))
    self.value = value
    self.version = 0
  end,

  snapshot = function(self)
    return {
      resource = self,
      version = self.version,
      value = self.value,
    }
  end,

  initial = function(_self, snap)
    return {
      base_version = snap.version,
      value = snap.value,
      written = false,
    }
  end,

  claim = function(self, snap, fragment, claim, ctx)
    local stale = ensure_fresh(self, snap, fragment, 'cell claim', ctx)
    if stale then return stale end

    local request = claim.request or claim.payload or claim or { tag = 'get' }
    local tag = request.tag or request[1]

    if tag == 'get' then
      return ctx:accept(copy_fragment(fragment), fragment.value)
    elseif tag == 'set' then
      return ctx:accept({
        base_version = fragment.base_version,
        value = request.value,
        written = true,
      }, true)
    elseif tag == 'update' then
      if type(request.fn) ~= 'function' then return ctx:fatal('cell update requires fn') end
      local next_value = request.fn(fragment.value)
      return ctx:accept({
        base_version = fragment.base_version,
        value = next_value,
        written = true,
      }, next_value)
    end

    return ctx:fatal('unknown cell request ' .. tostring(tag))
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
      return ctx:stale({ self }, 'cell fragment base version does not match current version')
    end
    local written = fragment.written and true or false
    return ctx:prepared({
      resource = self,
      fragment = copy_fragment(fragment),
      dirty = written and { self } or {},
      consequences = { transaction = {}, resource = {}, obligation = {} },
      target = fragment.value,
      written = written,
    })
  end,

  commit = function(self, prepared)
    if prepared.written then
      self.value = prepared.target
      self.version = self.version + 1
    end
  end,
}

function Cell.is(x)
  return type(x) == 'table' and x.__et_resource == true and x.link_name == 'cell'
end

function Cell.assert(x, where)
  if not Cell.is(x) then error((where or 'cell') .. ': expected Cell', 3) end
  return x
end

function Cell:get_op(Op)
  return Op.access(self, { tag = 'get' })
end

function Cell:set_op(Op, value)
  return Op.access(self, { tag = 'set', value = value })
end

function Cell:update_op(Op, fn)
  return Op.access(self, { tag = 'update', fn = fn })
end

function Cell:force_set(value)
  self.value = value
  self.version = self.version + 1
end

return Cell
