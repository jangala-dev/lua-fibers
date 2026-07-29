-- Interned dependency atoms, pending-request indexing and component coordination.
--
-- Every semantic dependency is one atom with a generation-bearing dense bucket.
-- The same atom identities and Bucket implementation are also used by the
-- blocked-demand index in domain.lua.

local IR = require('fibers.internal.kernel.ir')

local Bucket = {}
Bucket.__index = Bucket

function Bucket.new(kind, key, qualifier)
  return setmetatable({
    _fibers_dependency_bucket = true,
    kind = kind,
    key = key,
    qualifier = qualifier,
    generation = 0,
    count = 0,
    items = {},
    positions = {},
  }, Bucket)
end

local function assign(trail, target, key, value)
  if trail then
    trail:set(target, key, value)
  else
    target[key] = value
  end
end

local function append(trail, target, value)
  if trail then
    trail:push(target, value)
  else
    target[#target + 1] = value
  end
end

function Bucket:add(id, trail)
  if self.positions[id] then
    return false
  end
  local n = self.count + 1
  append(trail, self.items, id)
  assign(trail, self.positions, id, n)
  assign(trail, self, 'count', n)
  assign(trail, self, 'generation', self.generation + 1)
  return true
end

function Bucket:remove(id, trail)
  local position = self.positions[id]
  if not position then
    return false
  end
  local n, last = self.count, self.items[self.count]
  assign(trail, self.positions, id, nil)
  if position ~= n then
    assign(trail, self.items, position, last)
    assign(trail, self.positions, last, position)
  end
  assign(trail, self.items, n, nil)
  assign(trail, self, 'count', n - 1)
  assign(trail, self, 'generation', self.generation + 1)
  return true
end

function Bucket:contains(id)
  return self.positions[id] ~= nil
end

function Bucket:each(fn)
  for i = 1, self.count do
    fn(self.items[i])
  end
end

function Bucket:ids()
  local out = {}
  for i = 1, self.count do
    out[i] = self.items[i]
  end
  table.sort(out)
  return out
end

local AtomPool = {}
AtomPool.__index = AtomPool

function AtomPool.new()
  return setmetatable({ by_kind = {}, next_id = 0, none = {} }, AtomPool)
end

function AtomPool:intern(kind, object, qualifier)
  local by_object = self.by_kind[kind]
  if not by_object then
    by_object = {}
    self.by_kind[kind] = by_object
  end
  local object_key = object == nil and self.none or object
  local by_qualifier = by_object[object_key]
  if not by_qualifier then
    by_qualifier = {}
    by_object[object_key] = by_qualifier
  end
  local qualifier_key = qualifier == nil and self.none or qualifier
  local atom = by_qualifier[qualifier_key]
  if atom then
    return atom
  end
  self.next_id = self.next_id + 1
  atom = Bucket.new(kind, object, qualifier)
  atom._fibers_dependency_atom = true
  atom.id = self.next_id
  atom.object = object
  by_qualifier[qualifier_key] = atom
  return atom
end

local Index = {}
Index.__index = Index

local function opposite(role)
  if role == 'put' then
    return 'get'
  end
  if role == 'get' then
    return 'put'
  end
end

local function add_unique(out, seen, atom)
  if atom and not seen[atom] then
    seen[atom] = true
    out[#out + 1] = atom
  end
end

function Index.new()
  local pool = AtomPool.new()
  return setmetatable({
    pool = pool,
    size = 0,
    all_requests = pool:intern('all-requests'),
    opaque = pool:intern('opaque'),
  }, Index)
end

function Index:atom(kind, object, qualifier)
  return self.pool:intern(kind, object, qualifier)
end

function Index:_plan(metadata, request)
  local memberships, component_atoms, wide_pairs = {}, {}, {}
  local membership_seen, component_seen = {}, {}
  add_unique(memberships, membership_seen, self.all_requests)
  if IR.active_dynamic(metadata) then
    add_unique(memberships, membership_seen, self.opaque)
  end

  for resource, roles in pairs(metadata.exchanges or {}) do
    local all = self:atom('resource', resource, 'all')
    local wide = self:atom('resource', resource, 'wide')
    add_unique(memberships, membership_seen, all)
    for role in pairs(roles) do
      add_unique(memberships, membership_seen, self:atom('exchange', resource, role))
      add_unique(component_atoms, component_seen, self:atom('exchange', resource, opposite(role)))
    end
    wide_pairs[#wide_pairs + 1] = { wide = wide, all = all }
  end

  for location, access in pairs(metadata.locations or {}) do
    local touch = self:atom('location', location, 'touch')
    add_unique(memberships, membership_seen, touch)
    add_unique(component_atoms, component_seen, touch)
    local supplies = access.supplies or {}
    if supplies.up then
      add_unique(memberships, membership_seen, self:atom('supply', location, 'up'))
    end
    if supplies.down then
      add_unique(memberships, membership_seen, self:atom('supply', location, 'down'))
    end
    if supplies.any then
      add_unique(memberships, membership_seen, self:atom('supply', location, 'any'))
    end

    -- A Lifetime outcome is not merely another scalar: an operation currently
    -- running inside that Lifetime's Scope may causally advance it through
    -- several intermediate commits before the outcome is published.  Model the
    -- observer side as a directional exchange.  The opposite producer role is
    -- attached below to pending requests in the corresponding Scope.
    local completion = rawget(location, '_fibers_causal_lifetime')
      or rawget(location, '_fibers_completion_lifetime')
    if completion ~= nil then
      add_unique(memberships, membership_seen, self:atom('exchange', completion, 'get'))
      add_unique(component_atoms, component_seen, self:atom('exchange', completion, 'put'))
    end
  end

  -- Every pending operation in a Scope is a possible next causal step towards
  -- that Scope Lifetime's terminal outcome.  Producers use one directional
  -- role, so they are not connected to one another in ordinary component
  -- searches.  They are recruited only when an outcome observer contributes
  -- the opposite role.  This preserves local fallback liveness whilst retaining
  -- the positive-before-fallback rule for genuine completion dependencies.
  local scope = request and request.scope
  local completion = scope and scope._lifetime
  if completion ~= nil then
    add_unique(memberships, membership_seen, self:atom('exchange', completion, 'put'))
    add_unique(component_atoms, component_seen, self:atom('exchange', completion, 'get'))
  end

  for resource in pairs(metadata.resources or {}) do
    local all = self:atom('resource', resource, 'all')
    add_unique(memberships, membership_seen, all)
    add_unique(memberships, membership_seen, self:atom('resource', resource, 'wide'))
    add_unique(component_atoms, component_seen, all)
  end

  return { memberships = memberships, component_atoms = component_atoms, wide_pairs = wide_pairs }
end

function Index:add(request, metadata)
  if request._dependency_plan then
    self:remove(request)
  end
  metadata = metadata or request.metadata or IR.metadata(request.op)
  request.metadata = request.metadata or IR.metadata(request.op)
  local plan = self:_plan(metadata, request)
  plan.metadata = metadata
  request._dependency_plan = plan
  self.size = self.size + 1
  for i = 1, #plan.memberships do
    plan.memberships[i]:add(request.id)
  end
  return request
end

function Index:remove(request)
  local plan = request and request._dependency_plan
  if not plan then
    return
  end
  for i = 1, #plan.memberships do
    plan.memberships[i]:remove(request.id)
  end
  request._dependency_plan = nil
  self.size = math.max(0, self.size - 1)
end

local function record_dependency(meta, seen, atom)
  if atom and not seen[atom] then
    seen[atom] = true
    meta.dependencies[#meta.dependencies + 1] = atom
  end
end

local function visit_atom(atom, queue, seen_ids, pending, meta, dependency_seen)
  if not atom then
    return
  end
  record_dependency(meta, dependency_seen, atom)
  atom:each(function(id)
    if pending[id] and not seen_ids[id] then
      seen_ids[id], queue[#queue + 1] = true, id
    end
  end)
end

local MOD, MUL = 2147483647, 48271
local function mix_generation(state, value)
  return (state * MUL + math.floor(tonumber(value) or 0) % MOD) % MOD
end

local function component_generation(meta, ids)
  local atoms = {}
  for i = 1, #meta.dependencies do
    atoms[i] = meta.dependencies[i]
  end
  table.sort(atoms, function(a, b)
    return a.id < b.id
  end)
  local generation = 1
  for i = 1, #atoms do
    generation = mix_generation(generation, atoms[i].id)
    generation = mix_generation(generation, atoms[i].generation)
  end
  for i = 1, #ids do
    generation = mix_generation(generation, ids[i])
  end
  return generation
end

function Index:component(focus_id, pending)
  if not pending[focus_id] then
    return {}, { total = 0, size = 0, dynamic = self.opaque.count, dependencies = {} }
  end
  local meta = {
    total = self.size,
    size = 0,
    dynamic = self.opaque.count,
    global = false,
    edge_visits = 0,
    dependencies = {},
  }
  local dependency_seen = {}
  record_dependency(meta, dependency_seen, self.opaque)

  if self.opaque.count > 0 then
    record_dependency(meta, dependency_seen, self.all_requests)
    local out, ids = {}, {}
    self.all_requests:each(function(id)
      if pending[id] then
        out[id], ids[#ids + 1] = pending[id], id
      end
    end)
    table.sort(ids)
    meta.size, meta.global, meta.ids = #ids, true, ids
    meta.order_generation = component_generation(meta, ids)
    return out, meta
  end

  local seen, queue, head = { [focus_id] = true }, { focus_id }, 1
  while head <= #queue do
    local id = queue[head]
    head = head + 1
    local request = pending[id]
    local plan = request and request._dependency_plan
    if plan then
      for i = 1, #plan.component_atoms do
        meta.edge_visits = meta.edge_visits + 1
        visit_atom(plan.component_atoms[i], queue, seen, pending, meta, dependency_seen)
      end
      for i = 1, #plan.wide_pairs do
        local pair = plan.wide_pairs[i]
        record_dependency(meta, dependency_seen, pair.wide)
        if pair.wide.count > 0 then
          meta.edge_visits = meta.edge_visits + 1
          visit_atom(pair.all, queue, seen, pending, meta, dependency_seen)
        end
      end
    end
  end

  local out, ids = {}, {}
  for id in pairs(seen) do
    out[id], ids[#ids + 1] = pending[id], id
  end
  table.sort(ids)
  meta.size, meta.ids = #ids, ids
  meta.order_generation = component_generation(meta, ids)
  return out, meta
end

function Index:supplier_atoms(intent)
  local atoms, seen = {}, {}
  if intent.kind == 'exchange' then
    add_unique(atoms, seen, self:atom('exchange', intent.resource, opposite(intent.role)))
    add_unique(atoms, seen, self:atom('resource', intent.resource, 'wide'))
  else
    local program = intent.program
    local location = program and program.location
    if location then
      add_unique(atoms, seen, self:atom('supply', location, 'any'))
      local orientation = program.orientation
      if orientation == 'up' then
        add_unique(atoms, seen, self:atom('supply', location, 'up'))
      elseif orientation == 'down' then
        add_unique(atoms, seen, self:atom('supply', location, 'down'))
      else
        add_unique(atoms, seen, self:atom('supply', location, 'up'))
        add_unique(atoms, seen, self:atom('supply', location, 'down'))
      end
    end
  end
  return atoms
end

function Index:each_supplier(intents, pending, entered, excluded, fn, required_certainty)
  local possible, observed = {}, {}
  local function collect(atom)
    if not atom or observed[atom] then
      return
    end
    observed[atom] = true
    atom:each(function(id)
      possible[id] = true
    end)
  end
  collect(self.opaque)
  for i = 1, #(intents or {}) do
    local atoms = self:supplier_atoms(intents[i])
    for j = 1, #atoms do
      collect(atoms[j])
    end
  end

  local count = 0
  for id in pairs(possible) do
    local request = pending[id]
    if request and not (entered and entered[id]) and not (excluded and excluded[id]) then
      local score, certainty, reason = IR.supply_score(IR.active_metadata(request.metadata), intents)
      if score > 0 and (required_certainty == nil or certainty == required_certainty) then
        count = count + 1
        if fn(id, score, certainty, reason, request) == false then
          return count
        end
      end
    end
  end
  return count
end

Index.Bucket = Bucket
Index.AtomPool = AtomPool

return {
  Index = Index,
  Bucket = Bucket,
  AtomPool = AtomPool,
}
