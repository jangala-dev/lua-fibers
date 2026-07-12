-- Incremental pending-request dependency indexes.
--
-- The index is deliberately conservative.  Opaque continuations connect the
-- complete frontier; analysable requests are connected through complementary
-- exchange roles, shared locations and resource-wide observations.

local IR = require('fibers.kernel.ir')

local Index = {}
Index.__index = Index

local function set_add(map, key, id)
  local set = map[key]
  if not set then set = {}; map[key] = set end
  set[id] = true
end

local function set_remove(map, key, id)
  local set = map[key]
  if not set then return end
  set[id] = nil
  if next(set) == nil then map[key] = nil end
end

local function role_bucket(index, resource, role, create)
  local bucket = index.exchanges[resource]
  if not bucket and create then
    bucket = { put = {}, get = {} }
    index.exchanges[resource] = bucket
  end
  return bucket and bucket[role] or nil
end

function Index.new()
  return setmetatable({
    requests = {},
    exchanges = {},
    locations = {},
    location_suppliers = {},
    resource_all = {},
    resource_wide = {},
    dynamic = {},
    dynamic_count = 0,
    size = 0,
  }, Index)
end

function Index:add(request)
  if self.requests[request.id] then self:remove(self.requests[request.id]) end
  local metadata = request.metadata or request.footprint or IR.metadata(request.op)
  request.metadata, request.footprint = metadata, metadata
  self.requests[request.id] = request
  self.size = self.size + 1

  if metadata.dynamic then
    self.dynamic[request.id] = true
    self.dynamic_count = self.dynamic_count + 1
  end
  for resource, roles in pairs(metadata.exchanges or {}) do
    for role in pairs(roles) do
      local set = role_bucket(self, resource, role, true)
      set[request.id] = true
    end
    set_add(self.resource_all, resource, request.id)
  end
  for location, access in pairs(metadata.locations or {}) do
    set_add(self.locations, location, request.id)
    if access.supply then set_add(self.location_suppliers, location, request.id) end
  end
  for resource in pairs(metadata.resources or {}) do
    set_add(self.resource_all, resource, request.id)
    set_add(self.resource_wide, resource, request.id)
  end
  return request
end

function Index:remove(request)
  if not request or not self.requests[request.id] then return end
  local metadata = request.metadata or request.footprint or IR.metadata(request.op)
  self.requests[request.id] = nil
  self.size = math.max(0, self.size - 1)
  if self.dynamic[request.id] then
    self.dynamic[request.id] = nil
    self.dynamic_count = math.max(0, self.dynamic_count - 1)
  end
  for resource, roles in pairs(metadata.exchanges or {}) do
    local bucket = self.exchanges[resource]
    if bucket then
      for role in pairs(roles) do bucket[role][request.id] = nil end
      if next(bucket.put) == nil and next(bucket.get) == nil then self.exchanges[resource] = nil end
    end
    set_remove(self.resource_all, resource, request.id)
  end
  for location, access in pairs(metadata.locations or {}) do
    set_remove(self.locations, location, request.id)
    if access.supply then set_remove(self.location_suppliers, location, request.id) end
  end
  for resource in pairs(metadata.resources or {}) do
    set_remove(self.resource_all, resource, request.id)
    set_remove(self.resource_wide, resource, request.id)
  end
end

local function add_set(queue, seen, set, pending)
  for id in pairs(set or {}) do
    if pending[id] and not seen[id] then
      seen[id] = true
      queue[#queue + 1] = id
    end
  end
end

local function copy_pending(pending)
  local out, ids, n = {}, {}, 0
  for id, request in pairs(pending or {}) do out[id] = request; ids[#ids + 1] = id; n = n + 1 end
  table.sort(ids)
  return out, n, ids
end

local function ids_signature(ids)
  local parts = {}
  for i = 1, #(ids or {}) do parts[i] = tostring(ids[i]) end
  return table.concat(parts, ',')
end

function Index:component(focus_id, pending, diagnostics)
  local focus = pending[focus_id]
  if not focus then return {}, { total = 0, size = 0, dynamic = self.dynamic_count } end
  local total = 0
  for _ in pairs(pending) do total = total + 1 end

  -- An opaque continuation may expose any dependency after its prefix completes.
  -- It therefore joins every otherwise separate component.
  if self.dynamic_count > 0 then
    local all, n, ids = copy_pending(pending)
    local meta = { total = total, size = n, dynamic = self.dynamic_count, global = true }
    if diagnostics then meta.ids, meta.signature = ids, ids_signature(ids) end
    return all, meta
  end

  local seen, queue, head = { [focus_id] = true }, { focus_id }, 1
  local edge_visits = 0
  while head <= #queue do
    local id = queue[head]; head = head + 1
    local request = pending[id]
    local metadata = request and (request.metadata or request.footprint)
    if metadata then
      for resource, roles in pairs(metadata.exchanges or {}) do
        local bucket = self.exchanges[resource]
        if bucket then
          if roles.put then edge_visits = edge_visits + 1; add_set(queue, seen, bucket.get, pending) end
          if roles.get then edge_visits = edge_visits + 1; add_set(queue, seen, bucket.put, pending) end
        end
        -- Resource-wide operations, such as snapshots, conservatively connect
        -- every operation mentioning that resource.
        if self.resource_wide[resource] then
          edge_visits = edge_visits + 1
          add_set(queue, seen, self.resource_all[resource], pending)
        end
      end
      for location in pairs(metadata.locations or {}) do
        edge_visits = edge_visits + 1
        add_set(queue, seen, self.locations[location], pending)
      end
      for resource in pairs(metadata.resources or {}) do
        edge_visits = edge_visits + 1
        add_set(queue, seen, self.resource_all[resource], pending)
      end
    end
  end

  local out, ids = {}, diagnostics and {} or nil
  for id in pairs(seen) do
    out[id] = pending[id]
    if ids then ids[#ids + 1] = id end
  end
  local meta = {
    total = total,
    size = #queue,
    dynamic = 0,
    global = false,
    edge_visits = edge_visits,
  }
  if ids then table.sort(ids); meta.ids, meta.signature = ids, ids_signature(ids) end
  return out, meta
end

local function opposite(role)
  if role == 'put' then return 'get' end
  if role == 'get' then return 'put' end
end

function Index:supplier_ids(intents, pending, entered, excluded)
  local possible = {}
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    if intent.kind == 'exchange' then
      local bucket = self.exchanges[intent.resource]
      local role = opposite(intent.role)
      for id in pairs(bucket and bucket[role] or {}) do possible[id] = true end
      for id in pairs(self.resource_wide[intent.resource] or {}) do possible[id] = true end
    else
      local location = intent.program and (intent.program.location or intent.program.group)
      for id in pairs(location and self.location_suppliers[location] or {}) do possible[id] = true end
    end
  end
  for id in pairs(self.dynamic) do possible[id] = true end

  local rows = {}
  for id in pairs(possible) do
    local request = pending[id]
    if request and not (entered and entered[id]) and not (excluded and excluded[id]) then
      local score, reason = IR.supply_score(request.metadata or request.footprint, intents)
      if score > 0 then rows[#rows + 1] = { id = id, score = score, reason = reason } end
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)
  return rows
end

return Index
