-- Dynamic execution proofs and their persistent invalidation index.
--
-- A proof is the exact fact set produced by executing an operation to its
-- current boundary. The index owns only reverse resource membership and uses
-- versioned buckets to invalidate retained searches and completed Retry proofs.

local M = {}
local EMPTY = {}
local DEPS, INTERESTS, CHECKS, ACTIVATIONS = 1, 2, 3, 4

local function table_field(value, field)
  local out = value[field]
  if not out then out = {}; value[field] = out end
  return out
end

local function add_value(certificate, field, value)
  local values = certificate[field]
  if not values then values = {}; certificate[field] = values end
  for i = 1, #values do if values[i] == value then return end end
  values[#values + 1] = value
end

local DEP_FIELDS = 7
local function add_dependency(certificate, source, request, class, object, qualifier, version, latent)
  local flag = class == 'exchange' and 1 or class == 'location' and 2 or 4
  if latent then flag = flag * 8 end
  local seen = certificate[source] or 0
  if seen % (flag * 2) >= flag then return end
  certificate[source] = seen + flag
  local values = certificate[DEPS]
  if not values then values = {}; certificate[DEPS] = values end
  local n = #values
  values[n + 1], values[n + 2], values[n + 3], values[n + 4] = source, request, class, object
  values[n + 5], values[n + 6], values[n + 7] = qualifier or false, version or false, latent or false
  if not latent then certificate.membership_sensitive = true end
end

local function add_check(certificate, check, payload, activation)
  local values = certificate[CHECKS]
  if not values then values = {}; certificate[CHECKS] = values end
  for i = 1, #values, 3 do
    if values[i] == check and values[i + 1] == payload then return end
  end
  values[#values + 1], values[#values + 2], values[#values + 3] = check, payload, activation
end

function M.merge(dst, src)
  if not src then return dst end
  dst = dst or {}
  local deps = src[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    add_dependency(dst, deps[i], deps[i + 1], deps[i + 2], deps[i + 3], deps[i + 4], deps[i + 5], deps[i + 6])
  end
  for i = 1, #(src[INTERESTS] or EMPTY) do add_value(dst, INTERESTS, src[INTERESTS][i]) end
  for i = 1, #(src[CHECKS] or EMPTY), 3 do add_check(dst, src[CHECKS][i], src[CHECKS][i + 1], src[CHECKS][i + 2]) end
  for i = 1, #(src[ACTIVATIONS] or EMPTY) do add_value(dst, ACTIVATIONS, src[ACTIVATIONS][i]) end
  return dst
end

M.INTERESTS = INTERESTS

-- Preserve only participant-membership dependencies from a discarded
-- preferred branch. They invalidate on new compatible roots without retaining
-- the branch's state or external waits.
function M.merge_latent_frontier(dst, src)
  dst = dst or {}
  local deps = src and src[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    if not deps[i + 6] then
      add_dependency(dst, deps[i], deps[i + 1], deps[i + 2], deps[i + 3], deps[i + 4], deps[i + 5], true)
    end
  end
  return dst
end

local ACTIVATION_FACT, INTEREST_FACT, CHECK_FACT, LOCATION_FACT = {}, {}, {}, {}

function M.gate_facts(certificate)
  local out = {}
  for i = 1, #(certificate and certificate[ACTIVATIONS] or EMPTY) do
    local activation = certificate[ACTIVATIONS][i]
    out[#out + 1] = ACTIVATION_FACT
    for j = 1, #activation do out[#out + 1] = activation[j] end
  end
  return out
end

local function add_intent(certificate, activation, intent)
  if intent.kind == 'exchange' then
    add_dependency(certificate, intent, intent.request, 'exchange', intent.resource, intent.role)
  elseif intent.spec and intent.spec.location then
    local location = intent.spec.location
    add_dependency(certificate, intent, intent.request, 'location', location, nil, intent.observed_version or location.version or 0)
  end
  local resource = intent.resource or (intent.spec and intent.spec.resource)
  if resource and intent.kind ~= 'exchange' then
    add_dependency(certificate, intent, intent.request, 'resource', resource, nil, resource.version or 0)
  end
  if intent.interest then
    add_value(certificate, INTERESTS, intent.interest)
    activation[#activation + 1], activation[#activation + 2] =
      INTEREST_FACT, intent.interest.id or intent.interest
  end

  local check = intent.spec and intent.spec.absence_check
  if check then
    add_check(certificate, check, intent.payload, intent.activation)
    activation[#activation + 1], activation[#activation + 2] = CHECK_FACT, intent.activation
  end

  local location = intent.spec and intent.spec.location
  if location then
    activation[#activation + 1], activation[#activation + 2], activation[#activation + 3] =
      LOCATION_FACT, location, intent.observed_version or location.version
  end
end

function M.from_intents(intents)
  local certificate, activation = {}, {}
  for i = 1, #(intents or {}) do
    if intents[i].active ~= false then add_intent(certificate, activation, intents[i]) end
  end
  add_value(certificate, ACTIVATIONS, activation)
  return certificate
end

local function observe(deps, class, object, qualifier, version)
  local set = table_field(deps, class == 'exchange' and 'exchanges' or class == 'location' and 'locations' or 'resources')
  if class == 'exchange' then
    local roles = set[object]
    if not roles then roles = {}; set[object] = roles end
    roles[qualifier] = true
  elseif set[object] == nil then
    set[object] = version or object.version or true
  end
end

function M.frontiers(intents, roots, inherited)
  local frontiers = {}
  for request, root in pairs(roots or {}) do
    if root and not root.outcome then frontiers[request] = { dependencies = {}, complete = true } end
  end
  local current = M.from_intents(intents)
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    local frontier = intent.active and frontiers[intent.request]
    if frontier and (intent.kind == 'choice' or intent.kind == 'transition') then frontier.complete = false end
  end
  M.merge(current, inherited)
  local deps = current[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    local frontier = frontiers[deps[i + 1]]
    if frontier then
      local target = frontier.dependencies
      if deps[i + 6] then target = frontier.latent or {}; frontier.latent = target end
      observe(target, deps[i + 2], deps[i + 3], deps[i + 4], deps[i + 5])
    end
  end
  return frontiers
end

local Operation = require('fibers.internal.operation')

local GENERATION = {}
local function new_bucket() return { [GENERATION] = 0 } end

function M.ensure(engine)
  local value = engine.proof_graph
  if value then return value end
  value = {
    potential_exchange = {}, potential_location = {}, potential_resource = {},
    potential_dynamic = new_bucket(),
    exact_exchange = {}, exact_location = {}, exact_resource = {}, dirty = {},
  }
  engine.proof_graph = value
  for i = 1, #engine.pending do M.add_request(engine, engine.pending[i], true) end
  return value
end

local function opposite(role)
  return role == 'put' and 'get' or role == 'get' and 'put' or nil
end

local function add_membership(memberships, bucket, request)
  if bucket[request] then return end
  bucket[request] = true
  bucket[GENERATION] = bucket[GENERATION] + 1
  memberships[#memberships + 1] = bucket
end

local function remove_memberships(memberships, request, first)
  for i = #(memberships or EMPTY), first or 1, -1 do
    local bucket = memberships[i]
    if bucket[request] then
      bucket[request] = nil
      bucket[GENERATION] = bucket[GENERATION] + 1
    end
    memberships[i] = nil
  end
end

local function bucket(store, object, qualifier)
  if qualifier ~= nil then
    local row = store[object]
    if not row then row = {}; store[object] = row end
    store = row
  end
  local value = store[qualifier or object]
  if not value then value = new_bucket(); store[qualifier or object] = value end
  return value
end

local function potential_shape(request)
  local shape = request.metadata or Operation.shape(request.op)
  request.metadata = shape
  return shape, request.scope and request.scope._lifetime
end

local function mark_bucket(value, bucket, excluded)
  if not bucket then return end
  for request, present in pairs(bucket) do
    if present == true and request ~= excluded and request.pending then value.dirty[request] = true end
  end
end

local function index_potential(value, request)
  local shape, lifetime = potential_shape(request)
  local memberships = {}
  for resource, roles in pairs(shape.exchanges or EMPTY) do
    for role in pairs(roles) do add_membership(memberships, bucket(value.potential_exchange, resource, role), request) end
  end
  for location in pairs(shape.locations or EMPTY) do
    add_membership(memberships, bucket(value.potential_location, location), request)
    local causal = rawget(location, '_fibers_causal_lifetime') or rawget(location, '_fibers_completion_lifetime')
    if causal ~= nil then add_membership(memberships, bucket(value.potential_exchange, causal, 'get'), request) end
  end
  for resource in pairs(shape.resources or EMPTY) do add_membership(memberships, bucket(value.potential_resource, resource), request) end
  if lifetime ~= nil then add_membership(memberships, bucket(value.potential_exchange, lifetime, 'put'), request) end
  if shape.dynamic then add_membership(memberships, value.potential_dynamic, request) end
  request._memberships, request._potential_count = memberships, #memberships
  return shape, lifetime
end

function M.remove_request(engine, request)
  local value = engine.proof_graph
  if not request or not value then return end
  remove_memberships(request._memberships, request)
  request._memberships, request._potential_count, request._proof = nil, nil, nil
  value.dirty[request] = nil
  mark_bucket(value, value.potential_dynamic)
end

function M.add_request(engine, request, quiet_admission)
  local value = M.ensure(engine)
  local shape, lifetime = index_potential(value, request)
  if quiet_admission then return end

  for resource, roles in pairs(shape.exchanges or EMPTY) do
    for role in pairs(roles) do
      local exact, possible = value.exact_exchange[resource], value.potential_exchange[resource]
      mark_bucket(value, exact and exact[opposite(role)], request)
      mark_bucket(value, possible and possible[opposite(role)], request)
    end
  end
  for location in pairs(shape.locations or EMPTY) do
    mark_bucket(value, value.exact_location[location], request)
    mark_bucket(value, value.potential_location[location], request)
  end
  for resource in pairs(shape.resources or EMPTY) do
    mark_bucket(value, value.exact_resource[resource], request)
    mark_bucket(value, value.potential_resource[resource], request)
  end
  if lifetime ~= nil then
    local exact, possible = value.exact_exchange[lifetime], value.potential_exchange[lifetime]
    mark_bucket(value, exact and exact.get, request)
    mark_bucket(value, possible and possible.get, request)
  end
  mark_bucket(value, value.potential_dynamic, request)
end

local function same_set_map(left, right)
  left, right = left or EMPTY, right or EMPTY
  for key, item in pairs(left) do
    local other = right[key]
    if type(item) == 'table' and not same_set_map(item, other)
      or type(item) ~= 'table' and other ~= item then return false end
  end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function same_dependencies(left, right)
  left, right = left or EMPTY, right or EMPTY
  return same_set_map(left.exchanges, right.exchanges)
    and same_set_map(left.locations, right.locations)
    and same_set_map(left.resources, right.resources)
end

local function index_exact(value, request, frontier)
  local memberships, deps = request._memberships, frontier.dependencies
  for resource, roles in pairs(deps.exchanges or EMPTY) do
    for role in pairs(roles) do add_membership(memberships, bucket(value.exact_exchange, resource, role), request) end
  end
  for location in pairs(deps.locations or EMPTY) do add_membership(memberships, bucket(value.exact_location, location), request) end
  for resource in pairs(deps.resources or EMPTY) do add_membership(memberships, bucket(value.exact_resource, resource), request) end
end

function M.publish(engine, request, frontier)
  if not request or not request.pending then return nil end
  local value = M.ensure(engine)
  local old = request._proof
  local same = old and old.complete == frontier.complete
    and same_dependencies(old.dependencies, frontier.dependencies)
    and same_dependencies(old.latent, frontier.latent)
  if not same then
    remove_memberships(request._memberships, request, (request._potential_count or 0) + 1)
    index_exact(value, request, frontier)
  end
  request._proof, value.dirty[request] = frontier, nil
end

function M.touch_resource(engine, resource)
  local value = engine.proof_graph
  if value then mark_bucket(value, value.exact_resource[resource]) end
end

local function collect_bucket(bucket, out, seen)
  if not bucket then return end
  for request, present in pairs(bucket) do
    if present == true and request.pending and not seen[request] then seen[request] = true; out[#out + 1] = request end
  end
end

function M.component(engine, focus)
  local value = engine.proof_graph
  if not focus or not focus.pending then return {}, { size = 0 } end
  if not value then return { [focus] = true }, { size = 1, order_generation = 1 } end

  local queue, requests = { focus }, { [focus] = true }
  local head, size = 1, 0
  while head <= #queue do
    local request = queue[head]; head = head + 1
    if request.pending then
      size = size + 1
      local frontier = request._proof
      local description, potential, lifetime = frontier and frontier.complete and frontier.dependencies
      if not description then
        description, lifetime = potential_shape(request)
        potential = true
      end
      for resource, roles in pairs(description.exchanges or EMPTY) do
        for role in pairs(roles) do
          local other = opposite(role)
          local exact, possible = value.exact_exchange[resource], value.potential_exchange[resource]
          collect_bucket(exact and exact[other], queue, requests)
          collect_bucket(possible and possible[other], queue, requests)
        end
      end
      for location in pairs(description.locations or EMPTY) do
        collect_bucket(value.exact_location[location], queue, requests)
        collect_bucket(value.potential_location[location], queue, requests)
      end
      for resource in pairs(description.resources or EMPTY) do
        collect_bucket(value.exact_resource[resource], queue, requests)
        collect_bucket(value.potential_resource[resource], queue, requests)
      end
      if potential and lifetime ~= nil then
        local exact, possible = value.exact_exchange[lifetime], value.potential_exchange[lifetime]
        collect_bucket(exact and exact.get, queue, requests)
        collect_bucket(possible and possible.get, queue, requests)
      end
      if description.dynamic then
        for i = 1, #engine.pending do
          local candidate = engine.pending[i]
          if candidate.pending and not requests[candidate] then requests[candidate] = true; queue[#queue + 1] = candidate end
        end
      end
    end
  end
  return requests, { size = size, order_generation = engine.pending_generation }
end

local function add_bucket(snapshot, bucket)
  if bucket then table_field(snapshot, 'buckets')[bucket] = bucket[GENERATION] end
end

local function add_location(snapshot, location, version)
  if not location then return end
  local locations = table_field(snapshot, 'locations')
  if locations[location] == nil then locations[location] = version or location.version or 0 end
end

function M.capture(engine, state, certificate)
  local value = M.ensure(engine)
  for _, root in pairs(state.roots or EMPTY) do value.dirty[root.request] = nil end
  local snapshot = { requests = {} }
  for _, root in pairs(state.roots or EMPTY) do snapshot.requests[root.request] = root.request.order end
  for location, version in pairs((state.journal and state.journal.observed) or EMPTY) do
    add_location(snapshot, location, version)
  end

  local proof = M.from_intents(state.intents)
  M.merge(proof, certificate)
  local deps = proof[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    local class, object = deps[i + 2], deps[i + 3]
    if class == 'exchange' then
      local possible = value.potential_exchange[object]
      add_bucket(snapshot, possible and possible[opposite(deps[i + 4])])
    elseif class == 'location' then
      if not deps[i + 6] then add_location(snapshot, object, deps[i + 5]) end
      add_bucket(snapshot, value.potential_location[object])
    else
      add_bucket(snapshot, value.potential_resource[object])
    end
  end
  local checks = proof[CHECKS] or EMPTY
  if #checks > 0 then
    local out = table_field(snapshot, 'checks')
    for i = 1, #checks, 3 do out[#out + 1], out[#out + 2] = checks[i], checks[i + 1] end
  end
  for i = 1, #(proof[INTERESTS] or EMPTY) do
    local interest = proof[INTERESTS][i]
    if interest.kind == 'timer' and type(interest.deadline) == 'number' then
      local out = table_field(snapshot, 'timers'); out[#out + 1] = interest.deadline
    end
  end
  return snapshot
end

function M.valid(engine, snapshot)
  local value = engine.proof_graph
  if not snapshot then return false end
  for request, order in pairs(snapshot.requests or EMPTY) do
    if not request.pending or request.order ~= order then return false end
    if value and value.dirty[request] then return false end
  end
  for location, version in pairs(snapshot.locations or EMPTY) do
    if (location.version or 0) ~= version then return false end
  end
  for bucket, generation in pairs(snapshot.buckets or EMPTY) do
    if bucket[GENERATION] ~= generation then return false end
  end
  for i = 1, #(snapshot.checks or EMPTY), 2 do
    if not snapshot.checks[i](engine.runtime, snapshot.checks[i + 1]) then return false end
  end
  local now
  for i = 1, #(snapshot.timers or EMPTY) do
    now = now or engine.runtime:now()
    if now >= snapshot.timers[i] then return false end
  end
  return true
end

function M.retry(engine, request)
  local frontier = request and request._proof
  if not frontier or not frontier.retry then return nil end
  if not M.valid(engine, frontier.snapshot) then return nil end
  return frontier
end

return M
