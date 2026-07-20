-- Pending dependency indexing, retained-work validation and component coordination.
--
-- These three concerns form one runtime subsystem: promoted buckets identify
-- connected work, dependency vectors validate retained proofs, and component
-- coordinators organise those proofs without introducing another evaluator.

local IR = require('fibers.internal.kernel.ir')

local Index = {}
Index.__index = Index

local Bucket = {}
Bucket.__index = Bucket

local SMALL_LIMIT = 4

local function new_bucket(kind, key, role)
  return setmetatable({
    _fibers_dependency_bucket = true,
    kind = kind,
    key = key,
    role = role,
    generation = 0,
    count = 0,
    one = nil,
    small = nil,
    set = nil,
  }, Bucket)
end

function Bucket:add(id)
  if self.count == 0 then
    self.one, self.count = id, 1
  elseif self.count == 1 then
    if self.one == id then
      return false
    end
    self.small = { self.one, id }
    self.one, self.count = nil, 2
  elseif self.set then
    if self.set[id] then
      return false
    end
    self.set[id] = true
    self.count = self.count + 1
  else
    for i = 1, #self.small do
      if self.small[i] == id then
        return false
      end
    end
    self.small[#self.small + 1] = id
    self.count = self.count + 1
    if self.count > SMALL_LIMIT then
      local set = {}
      for i = 1, #self.small do
        set[self.small[i]] = true
      end
      self.set, self.small = set, nil
    end
  end
  self.generation = self.generation + 1
  return true
end

local function collect_set(set)
  local ids = {}
  for id in pairs(set or {}) do
    ids[#ids + 1] = id
  end
  return ids
end

function Bucket:remove(id)
  if self.count == 0 then
    return false
  end
  if self.count == 1 then
    if self.one ~= id then
      return false
    end
    self.one, self.count = nil, 0
  elseif self.set then
    if not self.set[id] then
      return false
    end
    self.set[id] = nil
    self.count = self.count - 1
    if self.count <= SMALL_LIMIT then
      self.small, self.set = collect_set(self.set), nil
    end
  else
    local found
    for i = 1, #self.small do
      if self.small[i] == id then
        table.remove(self.small, i)
        found = true
        break
      end
    end
    if not found then
      return false
    end
    self.count = self.count - 1
    if self.count == 1 then
      self.one, self.small = self.small[1], nil
    elseif self.count == 0 then
      self.small = nil
    end
  end
  self.generation = self.generation + 1
  return true
end

function Bucket:contains(id)
  if self.count == 0 then
    return false
  end
  if self.count == 1 then
    return self.one == id
  end
  if self.set then
    return self.set[id] == true
  end
  for i = 1, #self.small do
    if self.small[i] == id then
      return true
    end
  end
  return false
end

function Bucket:each(fn)
  if self.count == 0 then
    return
  end
  if self.count == 1 then
    fn(self.one)
    return
  end
  if self.set then
    for id in pairs(self.set) do
      fn(id)
    end
  else
    for i = 1, #self.small do
      fn(self.small[i])
    end
  end
end

function Bucket:ids()
  local ids = {}
  self:each(function(id)
    ids[#ids + 1] = id
  end)
  table.sort(ids)
  return ids
end

local function bucket(map, key, kind, create, role)
  local value = map[key]
  if not value and create then
    value = new_bucket(kind, key, role)
    map[key] = value
  end
  return value
end

local function exchange_group(index, resource, create)
  local group = index.exchanges[resource]
  if not group and create then
    group = {
      put = new_bucket('exchange-role', resource, 'put'),
      get = new_bucket('exchange-role', resource, 'get'),
    }
    index.exchanges[resource] = group
  end
  return group
end

local function location_supplier_group(index, location, create)
  local group = index.location_suppliers[location]
  if not group and create then
    group = {
      up = new_bucket('location-supplier', location, 'up'),
      down = new_bucket('location-supplier', location, 'down'),
      any = new_bucket('location-supplier', location, 'any'),
    }
    index.location_suppliers[location] = group
  end
  return group
end

local function supplier_directions(access)
  local supplies = access and access.supplies or nil
  return supplies and supplies.up == true or false,
    supplies and supplies.down == true or false,
    supplies and supplies.any == true or false
end

function Index.new()
  return setmetatable({
    requests = {},
    exchanges = {},
    locations = {},
    location_suppliers = {},
    resource_all = {},
    resource_wide = {},
    opaque = new_bucket('opaque', false),
    all_requests = new_bucket('all-requests', false),
    size = 0,
  }, Index)
end

function Index:_ensure_metadata_buckets(metadata)
  for resource in pairs(metadata.exchanges or {}) do
    exchange_group(self, resource, true)
    bucket(self.resource_all, resource, 'resource-all', true)
    bucket(self.resource_wide, resource, 'resource-wide', true)
  end
  for location in pairs(metadata.locations or {}) do
    bucket(self.locations, location, 'location-all', true)
    location_supplier_group(self, location, true)
  end
  for resource in pairs(metadata.resources or {}) do
    bucket(self.resource_all, resource, 'resource-all', true)
    bucket(self.resource_wide, resource, 'resource-wide', true)
  end
end

function Index:add(request)
  if self.requests[request.id] then
    self:remove(self.requests[request.id])
  end
  local metadata = request.metadata or request.footprint or IR.metadata(request.op)
  request.metadata, request.footprint = metadata, metadata
  self:_ensure_metadata_buckets(metadata)
  self.requests[request.id] = request
  self.size = self.size + 1
  self.all_requests:add(request.id)

  if metadata.dynamic then
    self.opaque:add(request.id)
  end
  for resource, roles in pairs(metadata.exchanges or {}) do
    local group = exchange_group(self, resource, true)
    for role in pairs(roles) do
      group[role]:add(request.id)
    end
    bucket(self.resource_all, resource, 'resource-all', true):add(request.id)
  end
  for location, access in pairs(metadata.locations or {}) do
    bucket(self.locations, location, 'location-all', true):add(request.id)
    local up, down, any = supplier_directions(access)
    if up or down or any then
      local suppliers = location_supplier_group(self, location, true)
      if up then
        suppliers.up:add(request.id)
      end
      if down then
        suppliers.down:add(request.id)
      end
      if any then
        suppliers.any:add(request.id)
      end
    end
  end
  for resource in pairs(metadata.resources or {}) do
    bucket(self.resource_all, resource, 'resource-all', true):add(request.id)
    bucket(self.resource_wide, resource, 'resource-wide', true):add(request.id)
  end
  return request
end

local function retire_empty(map, key)
  local value = map[key]
  if value and value.count == 0 then
    map[key] = nil
  end
end

local function retire_exchange_group(index, resource)
  local group = index.exchanges[resource]
  if group and group.put.count == 0 and group.get.count == 0 then
    index.exchanges[resource] = nil
  end
end

function Index:remove(request)
  if not request or not self.requests[request.id] then
    return
  end
  local metadata = request.metadata or request.footprint or IR.metadata(request.op)
  self.requests[request.id] = nil
  self.size = math.max(0, self.size - 1)
  self.all_requests:remove(request.id)
  if metadata.dynamic then
    self.opaque:remove(request.id)
  end

  for resource, roles in pairs(metadata.exchanges or {}) do
    local group = exchange_group(self, resource, false)
    if group then
      for role in pairs(roles) do
        group[role]:remove(request.id)
      end
    end
    local all = self.resource_all[resource]
    if all then
      all:remove(request.id)
    end
    retire_exchange_group(self, resource)
    retire_empty(self.resource_all, resource)
    retire_empty(self.resource_wide, resource)
  end
  for location, access in pairs(metadata.locations or {}) do
    local all = self.locations[location]
    if all then
      all:remove(request.id)
    end
    local up, down, any = supplier_directions(access)
    local suppliers = self.location_suppliers[location]
    if suppliers then
      if up then
        suppliers.up:remove(request.id)
      end
      if down then
        suppliers.down:remove(request.id)
      end
      if any then
        suppliers.any:remove(request.id)
      end
      if suppliers.up.count == 0 and suppliers.down.count == 0 and suppliers.any.count == 0 then
        self.location_suppliers[location] = nil
      end
    end
    retire_empty(self.locations, location)
  end
  for resource in pairs(metadata.resources or {}) do
    local all = self.resource_all[resource]
    if all then
      all:remove(request.id)
    end
    local wide = self.resource_wide[resource]
    if wide then
      wide:remove(request.id)
    end
    retire_empty(self.resource_all, resource)
    retire_empty(self.resource_wide, resource)
  end
end

local function record_dependency(meta, seen, value)
  if not value or seen[value] then
    return
  end
  seen[value] = true
  meta.dependencies[#meta.dependencies + 1] = value
end

local function add_bucket(queue, seen_ids, value, pending, meta, seen_dependencies)
  if not value then
    return
  end
  record_dependency(meta, seen_dependencies, value)
  value:each(function(id)
    if pending[id] and not seen_ids[id] then
      seen_ids[id] = true
      queue[#queue + 1] = id
    end
  end)
end

local function ids_signature(ids)
  local parts = {}
  for i = 1, #(ids or {}) do
    parts[i] = tostring(ids[i])
  end
  return table.concat(parts, ',')
end

local MOD = 2147483647
local MUL = 48271
local function mix_generation(state, value)
  if type(value) ~= 'number' then
    local text, hash = tostring(value or ''), 1
    for i = 1, #text do
      hash = (hash * 131 + text:byte(i)) % MOD
    end
    value = hash
  end
  return (state * MUL + math.floor(value) % MOD) % MOD
end

local function dependency_token(value)
  local key = value.key
  return table.concat({
    tostring(value.kind or ''),
    tostring(value.role or ''),
    tostring(type(key) == 'table' and (key.id or key._fibers_id or key.name) or key or ''),
  }, ':')
end

local function component_generation(meta, ids)
  local dependencies = {}
  for i = 1, #(meta.dependencies or {}) do
    dependencies[i] = meta.dependencies[i]
  end
  table.sort(dependencies, function(a, b)
    return dependency_token(a) < dependency_token(b)
  end)
  local generation = 1
  for i = 1, #dependencies do
    generation = mix_generation(generation, dependency_token(dependencies[i]))
    generation = mix_generation(generation, dependencies[i].generation or 0)
  end
  for i = 1, #(ids or {}) do
    generation = mix_generation(generation, ids[i])
  end
  return generation
end

function Index:component(focus_id, pending, diagnostics)
  local focus = pending[focus_id]
  if not focus then
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
  -- Every analysable component observes the opaque bucket: admission of a new
  -- opaque continuation must invalidate otherwise local retained work.
  record_dependency(meta, dependency_seen, self.opaque)

  if self.opaque.count > 0 then
    record_dependency(meta, dependency_seen, self.all_requests)
    local out, ids = {}, {}
    self.all_requests:each(function(id)
      if pending[id] then
        out[id] = pending[id]
        ids[#ids + 1] = id
      end
    end)
    table.sort(ids)
    meta.size, meta.global, meta.ids, meta.signature = #ids, true, ids, ids_signature(ids)
    meta.order_generation = component_generation(meta, ids)
    return out, meta
  end

  local seen, queue, head = { [focus_id] = true }, { focus_id }, 1
  while head <= #queue do
    local id = queue[head]
    head = head + 1
    local request = pending[id]
    local metadata = request and (request.metadata or request.footprint)
    if metadata then
      for resource, roles in pairs(metadata.exchanges or {}) do
        local group = exchange_group(self, resource, true)
        if roles.put then
          meta.edge_visits = meta.edge_visits + 1
          add_bucket(queue, seen, group.get, pending, meta, dependency_seen)
        end
        if roles.get then
          meta.edge_visits = meta.edge_visits + 1
          add_bucket(queue, seen, group.put, pending, meta, dependency_seen)
        end
        local wide = bucket(self.resource_wide, resource, 'resource-wide', true)
        record_dependency(meta, dependency_seen, wide)
        if wide.count > 0 then
          meta.edge_visits = meta.edge_visits + 1
          add_bucket(
            queue,
            seen,
            bucket(self.resource_all, resource, 'resource-all', true),
            pending,
            meta,
            dependency_seen
          )
        end
      end
      for location in pairs(metadata.locations or {}) do
        meta.edge_visits = meta.edge_visits + 1
        add_bucket(
          queue,
          seen,
          bucket(self.locations, location, 'location-all', true),
          pending,
          meta,
          dependency_seen
        )
      end
      for resource in pairs(metadata.resources or {}) do
        meta.edge_visits = meta.edge_visits + 1
        add_bucket(
          queue,
          seen,
          bucket(self.resource_all, resource, 'resource-all', true),
          pending,
          meta,
          dependency_seen
        )
      end
    end
  end

  local out, ids = {}, {}
  for id in pairs(seen) do
    out[id] = pending[id]
    ids[#ids + 1] = id
  end
  table.sort(ids)
  meta.size, meta.ids, meta.signature = #ids, ids, ids_signature(ids)
  meta.order_generation = component_generation(meta, ids)
  return out, meta
end

local function opposite(role)
  if role == 'put' then
    return 'get'
  end
  if role == 'get' then
    return 'put'
  end
end

function Index:supplier_ids(intents, pending, entered, excluded, dependencies)
  local possible, dependency_seen = {}, {}
  local function observe(value)
    if dependencies and value and not dependency_seen[value] then
      dependency_seen[value] = true
      dependencies[#dependencies + 1] = value
    end
  end
  observe(self.opaque)
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    if intent.kind == 'exchange' then
      local group = exchange_group(self, intent.resource, true)
      local role = opposite(intent.role)
      local role_set = group[role]
      observe(role_set)
      role_set:each(function(id)
        possible[id] = true
      end)
      local wide = bucket(self.resource_wide, intent.resource, 'resource-wide', true)
      observe(wide)
      wide:each(function(id)
        possible[id] = true
      end)
    else
      local program = intent.program
      local location = program and (program.location or program.group)
      local suppliers = location and location_supplier_group(self, location, true)
      if suppliers then
        local orientation = program and (program.orientation or program.demand_tag)
        local function add(values)
          observe(values)
          values:each(function(id)
            possible[id] = true
          end)
        end
        add(suppliers.any)
        if orientation == 'up' then
          add(suppliers.up)
        elseif orientation == 'down' then
          add(suppliers.down)
        else
          add(suppliers.up)
          add(suppliers.down)
        end
      end
    end
  end
  self.opaque:each(function(id)
    possible[id] = true
  end)

  local rows = {}
  for id in pairs(possible) do
    local request = pending[id]
    if request and not (entered and entered[id]) and not (excluded and excluded[id]) then
      local score, reason = IR.supply_score(request.metadata or request.footprint, intents)
      if score > 0 then
        rows[#rows + 1] = { id = id, score = score, reason = reason }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.id < b.id
  end)
  return rows
end

Index.Bucket = Bucket

local Vector = {}

local MOD = 2147483647
local MUL = 48271

local function residue(value)
  if type(value) == 'number' then
    return math.floor(value) % MOD
  end
  local text = tostring(value or '')
  local h = 1
  for i = 1, #text do
    h = (h * 131 + text:byte(i)) % MOD
  end
  return h
end

local function mix(state, value)
  return (state * MUL + residue(value)) % MOD
end

local function ordered_objects(values)
  local out = {}
  for value in pairs(values or {}) do
    out[#out + 1] = value
  end
  table.sort(out, function(a, b)
    local ai, bi = a.id or a._fibers_id, b.id or b._fibers_id
    if ai ~= nil and bi ~= nil and ai ~= bi then
      return tostring(ai) < tostring(bi)
    end
    return tostring(a) < tostring(b)
  end)
  return out
end

local function add_row(vector, seen, kind, object, value, extra)
  if not object or seen[object] then
    return
  end
  seen[object] = true
  vector.rows[#vector.rows + 1] = {
    kind = kind,
    object = object,
    value = value,
    extra = extra,
  }
  vector.generation = mix(vector.generation, kind)
  vector.generation = mix(vector.generation, object.id or object._fibers_id or tostring(object))
  vector.generation = mix(vector.generation, value)
end

function Vector.capture(runtime, requests, component, refutation)
  if not runtime.dependency_index then
    return nil, 'dependency-index-disabled'
  end
  local vector = {
    _fibers_dependency_vector = true,
    rows = {},
    generation = mix(1, runtime.choice_seed or 1),
    policy = {
      machine = runtime.machine_name,
      branch = runtime.branch_policy,
      normalise = runtime.normalise_search ~= false,
      symmetry = runtime.certified_symmetry ~= false,
    },
  }
  local seen, locations, resources = {}, {}, {}
  local has_external = false
  local precise_external = refutation ~= nil
  if component and component.dynamic and component.dynamic > 0 then
    vector.dynamic = true
    vector.rows[#vector.rows + 1] = { kind = 'runtime-epoch', object = runtime, value = runtime.epoch }
    vector.generation = mix(vector.generation, runtime.epoch)
  end

  for i = 1, #((component and component.dependencies) or {}) do
    local dependency = component.dependencies[i]
    add_row(vector, seen, 'bucket', dependency, dependency.generation or 0)
  end

  local ids = component and component.ids or nil
  if not ids then
    ids = {}
    for id in pairs(requests or {}) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
  end

  for i = 1, #ids do
    local id = ids[i]
    local request = requests[id]
    if not request then
      return nil, 'missing-request'
    end
    local metadata = request.metadata or request.footprint or IR.metadata(request.op)
    request.metadata, request.footprint = metadata, metadata
    if metadata.external then
      has_external = true
    end
    vector.rows[#vector.rows + 1] = {
      kind = 'request',
      id = id,
      object = request,
      op = request.op,
    }
    vector.generation = mix(vector.generation, id)
    vector.generation = mix(vector.generation, request.op and request.op._id or tostring(request.op))
    for location in pairs(metadata.locations or {}) do
      locations[location] = true
    end
    for resource in pairs(metadata.resources or {}) do
      resources[resource] = true
    end
  end

  if refutation then
    for i = 1, #((refutation and refutation.interests) or {}) do
      local interest = refutation.interests[i]
      if interest and interest.kind == 'timer' and type(interest.deadline) == 'number' then
        vector.rows[#vector.rows + 1] = {
          kind = 'timer',
          object = interest.resource or runtime,
          value = interest.deadline,
        }
        vector.generation = mix(vector.generation, 'timer')
        vector.generation = mix(vector.generation, interest.deadline)
      elseif interest and interest.kind == 'external' then
        local resource = interest.resource
        if resource and type(resource.version) == 'number' then
          resources[resource] = true
        else
          precise_external = false
        end
      else
        precise_external = false
      end
    end
  end

  if has_external and not precise_external then
    vector.rows[#vector.rows + 1] =
      { kind = 'external-generation', object = runtime, value = runtime.external_generation or 0 }
    vector.generation = mix(vector.generation, runtime.external_generation or 0)
    vector.external = true
  elseif has_external then
    vector.external = 'precise'
  end

  local ordered_locations = ordered_objects(locations)
  for i = 1, #ordered_locations do
    local location = ordered_locations[i]
    add_row(vector, seen, 'location', location, location.version or 0)
  end
  local ordered_resources = ordered_objects(resources)
  for i = 1, #ordered_resources do
    local resource = ordered_resources[i]
    if type(resource.version) ~= 'number' then
      return nil, 'unversioned-resource'
    end
    add_row(vector, seen, 'resource', resource, resource.version)
  end

  return vector
end

function Vector.valid(vector, runtime)
  if not vector then
    return false, 'missing'
  end
  local policy = vector.policy or {}
  if
    policy.machine ~= runtime.machine_name
    or policy.branch ~= runtime.branch_policy
    or policy.normalise ~= (runtime.normalise_search ~= false)
    or policy.symmetry ~= (runtime.certified_symmetry ~= false)
  then
    return false, 'policy'
  end
  local membership_reason
  for i = 1, #(vector.rows or {}) do
    local row = vector.rows[i]
    if row.kind == 'request' then
      if runtime.pending_by_id[row.id] ~= row.object or row.object.op ~= row.op then
        membership_reason = membership_reason or 'request'
      end
    elseif row.kind == 'bucket' then
      if row.object.generation ~= row.value then
        membership_reason = membership_reason or 'bucket'
      end
    elseif row.kind == 'external-generation' then
      if (runtime.external_generation or 0) ~= row.value then
        return false, 'external-generation'
      end
    elseif row.kind == 'timer' then
      if runtime:now() >= row.value then
        return false, 'timer'
      end
    elseif row.kind == 'runtime-epoch' then
      if runtime.epoch ~= row.value then
        return false, 'runtime-epoch'
      end
    elseif row.kind == 'location' or row.kind == 'resource' then
      if row.object.version ~= row.value then
        return false, row.kind
      end
    else
      return false, 'unknown-row'
    end
  end
  if membership_reason then
    return false, membership_reason
  end
  return true
end

function Vector.extend(vector, dependencies)
  if not vector or not dependencies then
    return vector
  end
  local seen = {}
  for i = 1, #(vector.rows or {}) do
    seen[vector.rows[i].object] = true
  end
  for i = 1, #dependencies do
    local dependency = dependencies[i]
    add_row(vector, seen, 'bucket', dependency, dependency.generation or 0)
  end
  return vector
end

local Coordinator = {}
Coordinator.__index = Coordinator

local function copy_ids(ids)
  local out = {}
  for i = 1, #(ids or {}) do
    out[i] = ids[i]
  end
  return out
end

local function merge_refutations(rows)
  local out = { interests = {}, checks = {} }
  local interests, checks = {}, {}
  for i = 1, #rows do
    local ref = rows[i]
    for j = 1, #((ref and ref.interests) or {}) do
      local item = ref.interests[j]
      local key = item.id or tostring(item)
      if not interests[key] then
        interests[key] = true
        out.interests[#out.interests + 1] = item
      end
    end
    for j = 1, #((ref and ref.checks) or {}) do
      local item = ref.checks[j]
      local key = item.id or tostring(item)
      if not checks[key] then
        checks[key] = true
        out.checks[#out.checks + 1] = item
      end
    end
  end
  return out
end

function Coordinator.new(runtime, component)
  local self = setmetatable({
    _fibers_component_coordinator = true,
    runtime = runtime,
    signature = component.signature or '',
    ids = {},
    members = {},
    sessions = {},
    dependency_generation = nil,
    choice_generation = nil,
    retry_dependencies = nil,
    retry_refutation = nil,
    cursor = 0,
  }, Coordinator)
  self:update(component)
  if runtime.instrumentation then
    runtime.instrumentation:inc('component_coordinators')
  end
  return self
end

function Coordinator:update(component)
  local generation = component.order_generation or 0
  if self.dependency_generation ~= generation then
    self.dependency_generation = generation
    self.choice_generation = {
      epoch = self.runtime.epoch,
      pending = self.runtime.pending_generation,
    }
    self.retry_dependencies = nil
    self.retry_refutation = nil
  end
  self.ids = copy_ids(component.ids)
  self.members = {}
  for i = 1, #self.ids do
    self.members[self.ids[i]] = true
  end
  component.choice_generation = self.choice_generation
  component.coordinator = self
  return component
end

function Coordinator:store(focus_id, row)
  self.sessions[focus_id] = row
  row.coordinator = self
  self.retry_dependencies = nil
  self.retry_refutation = nil
end

function Coordinator:remove(focus_id)
  self.sessions[focus_id] = nil
  self.retry_dependencies = nil
  self.retry_refutation = nil
end

function Coordinator:is_empty()
  return next(self.sessions) == nil and #self.ids == 0
end

local function dependencies_valid(rows, runtime)
  for i = 1, #(rows or {}) do
    local valid = Vector.valid(rows[i], runtime)
    if not valid then
      return false
    end
  end
  return true
end

function Coordinator:cached_retry()
  if self.retry_dependencies then
    if dependencies_valid(self.retry_dependencies, self.runtime) then
      return self.retry_refutation
    end
    self.retry_dependencies, self.retry_refutation = nil, nil
  end

  local rows, dependencies = {}, {}
  for i = 1, #self.ids do
    local row = self.sessions[self.ids[i]]
    if not row or (row.kind ~= 'retry' and row.kind ~= 'refutation') or not row.dependencies then
      return nil
    end
    if not Vector.valid(row.dependencies, self.runtime) then
      return nil
    end
    dependencies[#dependencies + 1] = row.dependencies
    rows[#rows + 1] = row.refutation
  end
  if #rows == 0 then
    return nil
  end
  self.retry_dependencies = dependencies
  self.retry_refutation = merge_refutations(rows)
  return self.retry_refutation
end

function Coordinator:ordered_ids()
  local out = copy_ids(self.ids)
  if #out < 2 then
    return out
  end
  local start = (self.cursor % #out) + 1
  local ordered = {}
  for offset = 0, #out - 1 do
    ordered[#ordered + 1] = out[((start + offset - 1) % #out) + 1]
  end
  return ordered
end

function Coordinator:advance_cursor(focus_id)
  for i = 1, #self.ids do
    if self.ids[i] == focus_id then
      self.cursor = i
      return
    end
  end
end

return {
  Index = Index,
  Vector = Vector,
  Coordinator = Coordinator,
}
