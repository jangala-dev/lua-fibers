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
  for i = 1, #values do if values[i] == value then return false end end
  values[#values + 1] = value
  return true
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
end

local function add_check(certificate, check, activation)
  local values = certificate[CHECKS]
  if not values then values = {}; certificate[CHECKS] = values end
  for i = 1, #values, 2 do if values[i] == check then return false end end
  values[#values + 1], values[#values + 2] = check, activation
  return true
end

function M.merge(dst, src)
  if not src then return dst end
  dst = dst or {}
  local deps = src[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    add_dependency(dst, deps[i], deps[i + 1], deps[i + 2], deps[i + 3], deps[i + 4], deps[i + 5], deps[i + 6])
  end
  for i = 1, #(src[INTERESTS] or EMPTY) do add_value(dst, INTERESTS, src[INTERESTS][i]) end
  for i = 1, #(src[CHECKS] or EMPTY), 2 do add_check(dst, src[CHECKS][i], src[CHECKS][i + 1]) end
  for i = 1, #(src[ACTIVATIONS] or EMPTY) do add_value(dst, ACTIVATIONS, src[ACTIVATIONS][i]) end
  dst.membership_sensitive = dst.membership_sensitive or src.membership_sensitive
  return dst
end

function M.interests(certificate) return certificate and certificate[INTERESTS] end

function M.collect_interests(proofs)
  local out = {}
  for i = 1, #(proofs or {}) do
    local proof = proofs[i]
    local interests = proof and (proof[INTERESTS] or proof.interests) or EMPTY
    for j = 1, #interests do out[#out + 1] = interests[j] end
  end
  return out
end

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

-- Record whether a preferred-side absence proof depends on the current
-- participant frontier. Closed proofs such as `never` cannot be invalidated by
-- admitting another fiber; exchange, location and resource frontiers can.
function M.mark_absence_gate_frontier(certificate)
  local deps = certificate and certificate[DEPS] or EMPTY
  for i = 1, #deps, DEP_FIELDS do
    if not deps[i + 6] then certificate.membership_sensitive = true; break end
  end
end

local function add_intent_dependency(certificate, intent, class, object, qualifier, version)
  add_dependency(certificate, intent, intent.request, class, object, qualifier, version)
end

local function add_intent(certificate, activation, intent)
  if intent.kind == 'exchange' then
    add_intent_dependency(certificate, intent, 'exchange', intent.resource, intent.role)
  elseif intent.spec and intent.spec.location then
    local location = intent.spec.location
    add_intent_dependency(certificate, intent, 'location', location, nil, intent.observed_version or location.version or 0)
  end
  local resource = intent.resource or (intent.spec and intent.spec.resource)
  if resource and intent.kind ~= 'exchange' then
    add_intent_dependency(certificate, intent, 'resource', resource, nil, resource.version or 0)
  end
  if intent.interest then
    add_value(certificate, INTERESTS, intent.interest)
    activation[#activation + 1], activation[#activation + 2] =
      INTEREST_FACT, intent.interest.id or intent.interest
  end

  local check = intent.absence_check
  if check then
    add_check(certificate, check, intent.activation)
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
  for i = 1, #(intents or {}) do add_intent(certificate, activation, intents[i]) end
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
    if root and not root.done then
      frontiers[request] = { dependencies = {}, complete = true }
    end
  end
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    local frontier = intent.active and frontiers[intent.request]
    if frontier then
      if intent.kind == 'exchange' then
        observe(frontier.dependencies, 'exchange', intent.resource, intent.role)
      elseif intent.kind == 'choice' or intent.kind == 'transition' then
        frontier.complete = false
      end
      local leaf = intent.spec
      if leaf and leaf.location then observe(frontier.dependencies, 'location', leaf.location, nil, intent.observed_version) end
      local resource = intent.resource or (leaf and leaf.resource)
      if resource and intent.kind ~= 'exchange' then observe(frontier.dependencies, 'resource', resource) end
    end
  end
  local deps = inherited and inherited[DEPS] or EMPTY
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

local function new_bucket()
  return { generation = 0, items = {} }
end

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

local function bucket_add(bucket, request)
  if bucket.items[request] then return false end
  bucket.items[request] = true
  bucket.generation = bucket.generation + 1
  return true
end

local function bucket_remove(bucket, request)
  if not bucket.items[request] then return false end
  bucket.items[request] = nil
  bucket.generation = bucket.generation + 1
  return true
end

local function opposite(role)
  if role == 'put' then return 'get' end
  if role == 'get' then return 'put' end
end

local function bucket2(store, object, qualifier)
  local row = store[object]
  if not row then row = {}; store[object] = row end
  local bucket = row[qualifier]
  if not bucket then bucket = new_bucket(); row[qualifier] = bucket end
  return bucket
end

local function bucket1(store, object)
  local bucket = store[object]
  if not bucket then bucket = new_bucket(); store[object] = bucket end
  return bucket
end

local function add_membership(memberships, bucket, request)
  if bucket_add(bucket, request) then memberships[#memberships + 1] = bucket end
end

local function remove_memberships(memberships, request)
  for i = 1, #(memberships or EMPTY) do bucket_remove(memberships[i], request) end
end

local function potential_shape(request)
  local shape = request.metadata or Operation.shape(request.op)
  request.metadata = shape
  local scope = request.scope
  return shape, scope and scope._lifetime
end

local function mark_bucket(value, bucket, excluded)
  if not bucket then return end
  for request in pairs(bucket.items) do
    if request ~= excluded and request.pending then value.dirty[request] = true end
  end
end

local function index_potential(value, request)
  local shape, lifetime = potential_shape(request)
  local memberships = {}
  for resource, roles in pairs(shape.exchanges or EMPTY) do
    for role in pairs(roles) do add_membership(memberships, bucket2(value.potential_exchange, resource, role), request) end
  end
  for location in pairs(shape.locations or EMPTY) do
    add_membership(memberships, bucket1(value.potential_location, location), request)
    local causal = rawget(location, '_fibers_causal_lifetime') or rawget(location, '_fibers_completion_lifetime')
    if causal ~= nil then add_membership(memberships, bucket2(value.potential_exchange, causal, 'get'), request) end
  end
  for resource in pairs(shape.resources or EMPTY) do add_membership(memberships, bucket1(value.potential_resource, resource), request) end
  if lifetime ~= nil then add_membership(memberships, bucket2(value.potential_exchange, lifetime, 'put'), request) end
  if shape.dynamic then add_membership(memberships, value.potential_dynamic, request) end
  request._potential_memberships = memberships
  return shape, lifetime
end

function M.remove_request(engine, request)
  local value = engine.proof_graph
  if not request or not value then return end
  local memberships = request._potential_memberships
  if memberships then
    remove_memberships(memberships, request)
    request._potential_memberships = nil
  end
  local proof = request._proof
  if proof then remove_memberships(proof.memberships, request); request._proof = nil end
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
  for key, item in pairs(left or EMPTY) do
    local other = (right or EMPTY)[key]
    if type(item) == 'table' then
      if type(other) ~= 'table' then return false end
      for sub in pairs(item) do if not other[sub] then return false end end
      for sub in pairs(other) do if not item[sub] then return false end end
    elseif other ~= item then return false end
  end
  for key in pairs(right or EMPTY) do if (left or EMPTY)[key] == nil then return false end end
  return true
end

local function same_dependencies(left, right)
  left, right = left or EMPTY, right or EMPTY
  return same_set_map(left.exchanges, right.exchanges)
    and same_set_map(left.locations, right.locations)
    and same_set_map(left.resources, right.resources)
end

local function same_frontier(left, right)
  return left ~= nil and left.complete == right.complete
    and same_dependencies(left.dependencies, right.dependencies)
    and same_dependencies(left.latent, right.latent)
end

local function index_exact(value, request, frontier)
  local memberships, deps = {}, frontier.dependencies
  for resource, roles in pairs(deps.exchanges or EMPTY) do
    for role in pairs(roles) do add_membership(memberships, bucket2(value.exact_exchange, resource, role), request) end
  end
  for location in pairs(deps.locations or EMPTY) do add_membership(memberships, bucket1(value.exact_location, location), request) end
  for resource in pairs(deps.resources or EMPTY) do add_membership(memberships, bucket1(value.exact_resource, resource), request) end
  return memberships
end

function M.publish(engine, request, frontier)
  if not request or not request.pending then return nil end
  local value = M.ensure(engine)
  local old = request._proof
  if not same_frontier(old, frontier) then
    if old then remove_memberships(old.memberships, request) end
    frontier.memberships = index_exact(value, request, frontier)
  else
    frontier.memberships = old.memberships
  end
  request._proof, value.dirty[request] = frontier, nil
end

function M.touch_location(engine, location)
  local value = engine.proof_graph
  if value then mark_bucket(value, value.exact_location[location]) end
end

function M.touch_resource(engine, resource)
  local value = engine.proof_graph
  if value then mark_bucket(value, value.exact_resource[resource]) end
end

local function collect_bucket(bucket, out, seen)
  if not bucket then return end
  for request in pairs(bucket.items) do
    if request.pending and not seen[request] then seen[request] = true; out[#out + 1] = request end
  end
end

local function row_description(request)
  local frontier = request and request._proof
  if frontier and frontier.complete then return frontier.dependencies, false end
  local shape, lifetime = potential_shape(request)
  return shape, true, lifetime
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
      local description, potential, lifetime = row_description(request)
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
  if bucket then table_field(snapshot, 'buckets')[bucket] = bucket.generation end
end

local function add_location(snapshot, location, version)
  if not location then return end
  local locations = table_field(snapshot, 'locations')
  if locations[location] == nil then locations[location] = version or location.version or 0 end
end

local function add_check(snapshot, check)
  if check then local out = table_field(snapshot, 'checks'); out[#out + 1] = check end
end

local function add_timer(snapshot, interest)
  if interest and interest.kind == 'timer' and type(interest.deadline) == 'number' then
    local out = table_field(snapshot, 'timers'); out[#out + 1] = interest.deadline
  end
end

local function add_request(snapshot, request)
  if request then snapshot.requests[request] = request.order end
end

function M.acknowledge(engine, state)
  local value = engine.proof_graph
  if not value then return end
  for _, root in pairs((state and state.roots) or EMPTY) do value.dirty[root.request] = nil end
end

function M.capture(engine, state, certificate)
  local value = M.ensure(engine)
  local snapshot = { requests = {} }
  for _, root in pairs(state.roots or EMPTY) do add_request(snapshot, root.request) end
  for location, version in pairs((state.journal and state.journal.observed) or EMPTY) do
    add_location(snapshot, location, version)
  end

  local demanded
  local function add_exchange(resource, role)
    demanded = demanded or {}
    local roles = demanded[resource]
    if not roles then roles = {}; demanded[resource] = roles end
    if roles[role] then return end
    roles[role] = true
    local possible = value.potential_exchange[resource]
    add_bucket(snapshot, possible and possible[opposite(role)])
  end
  local function add_certificate(proof)
    if not proof then return end
    local deps = proof[DEPS] or EMPTY
    for i = 1, #deps, DEP_FIELDS do
      local class, object = deps[i + 2], deps[i + 3]
      if class == 'exchange' then
        add_exchange(object, deps[i + 4])
      elseif class == 'location' then
        if not deps[i + 6] then add_location(snapshot, object, deps[i + 5]) end
        add_bucket(snapshot, value.potential_location[object])
      else
        add_bucket(snapshot, value.potential_resource[object])
      end
    end
    for i = 1, #(proof[CHECKS] or EMPTY), 2 do add_check(snapshot, proof[CHECKS][i]) end
    for i = 1, #(proof[INTERESTS] or EMPTY) do add_timer(snapshot, proof[INTERESTS][i]) end
  end
  for i = 1, #(state.intents or EMPTY) do
    local intent = state.intents[i]
    if intent.active then
      if intent.kind == 'exchange' then
        add_exchange(intent.resource, intent.role)
      else
        local leaf = intent.spec
        if leaf and leaf.location then
          add_location(snapshot, leaf.location, intent.observed_version)
          add_bucket(snapshot, value.potential_location[leaf.location])
        end
        local resource = intent.resource or (leaf and leaf.resource)
        if resource then add_bucket(snapshot, value.potential_resource[resource]) end
      end
      add_check(snapshot, intent.absence_check)
      add_timer(snapshot, intent.interest)
    end
  end
  add_certificate(certificate)
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
    if bucket.generation ~= generation then return false end
  end
  for i = 1, #(snapshot.checks or EMPTY) do
    local check = snapshot.checks[i]
    if not check(engine.runtime) then return false end
  end
  local now
  for i = 1, #(snapshot.timers or EMPTY) do
    now = now or engine.runtime:now()
    if now >= snapshot.timers[i] then return false end
  end
  return true
end

function M.retry(engine, request)
  local value = engine.proof_graph
  local frontier = request and request._proof
  if not frontier or not frontier.retry or (value and value.dirty[request]) then return nil end
  if not M.valid(engine, frontier.snapshot) then return nil end
  return frontier
end

return M
