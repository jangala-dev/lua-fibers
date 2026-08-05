-- Dynamic execution proofs and their persistent invalidation index.
--
-- A proof is the exact fact set produced by executing an operation to its
-- current boundary. The index owns only reverse resource membership and uses
-- versioned buckets to invalidate retained searches and completed Retry proofs.

local M = {}

local function identity(fact)
  return fact.identity or fact.object or fact.value or false
end

local function same_fact(left, right)
  return left.kind == right.kind and identity(left) == identity(right)
end

local function add_unique(certificate, fact)
  for i = 1, #certificate do
    if same_fact(certificate[i], fact) then
      return false
    end
  end
  certificate[#certificate + 1] = fact
  return true
end

function M.new() return {} end

function M.add(certificate, kind, fields)
  certificate = certificate or M.new()
  local fact = fields or {}
  fact.kind = kind
  add_unique(certificate, fact)
  return certificate
end

function M.copy(certificate)
  if not certificate then
    return nil
  end
  local out = M.new()
  for i = 1, #certificate do out[i] = certificate[i]
  end
  return out
end

function M.merge(dst, src)
  if not src then
    return dst
  end
  dst = dst or M.new()
  for i = 1, #src do add_unique(dst, src[i])
  end
  return dst
end

function M.collect_interests(proofs)
  local out = {}
  for i = 1, #(proofs or {}) do
    local proof = proofs[i]
    for j = 1, #(proof or {}) do
      local fact = proof[j]
      if fact.kind == 'interest' then out[#out + 1] = fact.value end
    end
  end
  return out
end

-- Preserve only the proof's participant-membership frontier. These facts
-- invalidate when a new compatible pending root appears, but do not keep a
-- discarded preferred branch registered as a live state or external wait.
function M.merge_latent_frontier(dst, src)
  dst = dst or M.new()
  for i = 1, #(src or {}) do
    local fact = src[i]
    local latent_kind
    if fact.kind == 'frontier-exchange' then
      latent_kind = 'latent-frontier-exchange'
    elseif fact.kind == 'frontier-location' then
      latent_kind = 'latent-frontier-location'
    elseif fact.kind == 'frontier-resource' then
      latent_kind = 'latent-frontier-resource'
    end
    if latent_kind then
      local copy = {}
      for key, value in pairs(fact) do copy[key] = value end
      copy.kind = latent_kind
      copy.identity = identity(fact)
      add_unique(dst, copy)
    end
  end
  return dst
end

local ACTIVATION_FACT, INTEREST_FACT, CHECK_FACT, LOCATION_FACT = {}, {}, {}, {}

function M.gate_facts(certificate)
  local out = {}
  for i = 1, #(certificate or {}) do
    local fact = certificate[i]
    if fact.kind == 'activation' then
      out[#out + 1] = ACTIVATION_FACT
      for j = 1, #(fact.value or {}) do out[#out + 1] = fact.value[j] end
    end
  end
  return out
end

-- Record whether a preferred-side absence proof depends on the current
-- participant frontier. Closed proofs such as `never` cannot be invalidated by
-- admitting another fiber; exchange, location and resource frontiers can.
function M.mark_absence_gate_frontier(certificate)
  for i = 1, #(certificate or {}) do
    local kind = certificate[i].kind
    if kind == 'frontier-exchange' or kind == 'frontier-location' or kind == 'frontier-resource' then
      certificate.membership_sensitive = true
      break
    end
  end
end

local function add_intent(certificate, activation, intent)
  if intent.kind == 'exchange' then
    M.add(certificate, 'frontier-exchange', {
      identity = intent,
      request = intent.request, resource = intent.resource, role = intent.role, name = intent.name,
    })
  elseif intent.spec and intent.spec.location then
    local location = intent.spec.location
    M.add(certificate, 'frontier-location', {
      identity = intent,
      request = intent.request, location = location, name = intent.name,
      version = intent.observed_version or location.version or 0,
    })
  end
  local resource = intent.resource or (intent.spec and intent.spec.resource)
  if resource and intent.kind ~= 'exchange' then
    M.add(certificate, 'frontier-resource', {
      identity = intent,
      request = intent.request, resource = resource, name = intent.name, version = resource.version or 0,
    })
  end
  if intent.interest then
    M.add(certificate, 'interest', { identity = intent.interest, value = intent.interest })
    activation[#activation + 1], activation[#activation + 2] =
      INTEREST_FACT, intent.interest.id or intent.interest
  end

  local check = intent.absence_check
  if check then
    local key = check.id or check.validate or check
    M.add(certificate, 'check', { identity = key, value = check })
    activation[#activation + 1], activation[#activation + 2] = CHECK_FACT, check.id or intent.activation
  end

  local location = intent.spec and intent.spec.location
  if location then
    activation[#activation + 1], activation[#activation + 2], activation[#activation + 3] =
      LOCATION_FACT, location, intent.observed_version or location.version
  end
end

local function finish_activation(certificate, activation)
  M.add(certificate, 'activation', { value = activation })
  return certificate
end

function M.from_intents(intents)
  local certificate, activation = M.new(), {}
  for i = 1, #(intents or {}) do add_intent(certificate, activation, intents[i]) end
  return finish_activation(certificate, activation)
end

function M.frontiers(intents, roots, inherited)
  local frontiers, activations = {}, {}
  for request, root in pairs(roots or {}) do
    if root and not root.done then
      frontiers[request] = {
        exchanges = {}, locations = {}, resources = {},
        latent_exchanges = {}, latent_locations = {}, latent_resources = {},
        complete = true, certificate = M.new(),
      }
      activations[request] = {}
    end
  end

  local function observe(frontier, kind, object, qualifier, version)
    if kind == 'exchange' then
      local roles = frontier.exchanges[object]
      if not roles then roles = {}; frontier.exchanges[object] = roles end
      if roles[qualifier] then return end
      roles[qualifier] = true
    elseif kind == 'location' then
      if frontier.locations[object] ~= nil then return end
      frontier.locations[object] = version or object.version or 0
    else
      if frontier.resources[object] ~= nil then return end
      frontier.resources[object] = version or object.version or 0
    end
  end

  for i = 1, #(intents or {}) do
    local intent = intents[i]
    local frontier = intent.active and frontiers[intent.request]
    if frontier then
      add_intent(frontier.certificate, activations[intent.request], intent)
      if intent.kind == 'exchange' then
        observe(frontier, 'exchange', intent.resource, intent.role)
      elseif intent.kind == 'choice' or intent.kind == 'witness' or intent.kind == 'transition' then
        frontier.complete = false
      end
      local leaf = intent.spec
      if leaf and leaf.location then observe(frontier, 'location', leaf.location, nil, intent.observed_version) end
      local resource = intent.resource or (leaf and leaf.resource)
      if resource and intent.kind ~= 'exchange' then observe(frontier, 'resource', resource) end
    end
  end

  for i = 1, #(inherited or {}) do
    local fact = inherited[i]
    local frontier = frontiers[fact.request]
    if frontier then
      if fact.kind == 'frontier-exchange' then observe(frontier, 'exchange', fact.resource, fact.role)
      elseif fact.kind == 'frontier-location' then observe(frontier, 'location', fact.location, nil, fact.version)
      elseif fact.kind == 'frontier-resource' then observe(frontier, 'resource', fact.resource, nil, fact.version)
      elseif fact.kind == 'latent-frontier-exchange' then
        local roles = frontier.latent_exchanges[fact.resource]
        if not roles then roles = {}; frontier.latent_exchanges[fact.resource] = roles end
        roles[fact.role] = true
      elseif fact.kind == 'latent-frontier-location' then frontier.latent_locations[fact.location] = true
      elseif fact.kind == 'latent-frontier-resource' then frontier.latent_resources[fact.resource] = true
      end
    end
  end

  for request, frontier in pairs(frontiers) do
    frontier.certificate = finish_activation(frontier.certificate, activations[request])
  end
  return frontiers
end

local Operation = require('fibers.internal.operation')

local EMPTY = {}

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

local function mark_dirty(value, request, reason)
  if request and request.pending then value.dirty[request] = reason or true end
end

local function mark_bucket(value, bucket, reason, excluded)
  if not bucket then return end
  for request in pairs(bucket.items) do
    if request ~= excluded then mark_dirty(value, request, reason) end
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

function M.remove_request(engine, request, quiet)
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
  if not quiet then mark_bucket(value, value.potential_dynamic, 'pending-root-removed') end
end

function M.add_request(engine, request, quiet_admission)
  local value = M.ensure(engine)
  local shape, lifetime = index_potential(value, request)
  if quiet_admission then return end

  for resource, roles in pairs(shape.exchanges or EMPTY) do
    for role in pairs(roles) do
      local exact, possible = value.exact_exchange[resource], value.potential_exchange[resource]
      mark_bucket(value, exact and exact[opposite(role)], 'new-supplier', request)
      mark_bucket(value, possible and possible[opposite(role)], 'new-potential-supplier', request)
    end
  end
  for location in pairs(shape.locations or EMPTY) do
    mark_bucket(value, value.exact_location[location], 'new-location-participant', request)
    mark_bucket(value, value.potential_location[location], 'new-potential-location-participant', request)
  end
  for resource in pairs(shape.resources or EMPTY) do
    mark_bucket(value, value.exact_resource[resource], 'new-resource-participant', request)
    mark_bucket(value, value.potential_resource[resource], 'new-potential-resource-participant', request)
  end
  if lifetime ~= nil then
    local exact, possible = value.exact_exchange[lifetime], value.potential_exchange[lifetime]
    mark_bucket(value, exact and exact.get, 'new-supplier', request)
    mark_bucket(value, possible and possible.get, 'new-potential-supplier', request)
  end
  mark_bucket(value, value.potential_dynamic, 'new-pending-root', request)
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

local function same_frontier(left, right)
  return left ~= nil
    and left.complete == right.complete
    and same_set_map(left.exchanges, right.exchanges)
    and same_set_map(left.locations, right.locations)
    and same_set_map(left.resources, right.resources)
    and same_set_map(left.latent_exchanges, right.latent_exchanges)
    and same_set_map(left.latent_locations, right.latent_locations)
    and same_set_map(left.latent_resources, right.latent_resources)
end

local function index_exact(value, request, frontier)
  local memberships = {}
  for resource, roles in pairs(frontier.exchanges or EMPTY) do
    for role in pairs(roles) do add_membership(memberships, bucket2(value.exact_exchange, resource, role), request) end
  end
  for location in pairs(frontier.locations or EMPTY) do add_membership(memberships, bucket1(value.exact_location, location), request) end
  for resource in pairs(frontier.resources or EMPTY) do add_membership(memberships, bucket1(value.exact_resource, resource), request) end
  return memberships
end

function M.publish(engine, request, frontier)
  if not request or not request.pending then return nil end
  local value = M.ensure(engine)
  if not request._potential_memberships then M.add_request(engine, request, true) end
  local old = request._proof
  if not same_frontier(old, frontier) then
    if old then remove_memberships(old.memberships, request) end
    frontier.memberships = index_exact(value, request, frontier)
  else
    frontier.memberships = old.memberships
  end
  request._proof, value.dirty[request] = frontier, nil
end

function M.touch_location(engine, location, reason)
  local value = engine.proof_graph
  if value then mark_bucket(value, value.exact_location[location], reason or 'location-version') end
end

function M.touch_resource(engine, resource, reason)
  local value = engine.proof_graph
  if value then mark_bucket(value, value.exact_resource[resource], reason or 'resource-version') end
end

local function collect_bucket(bucket, out, seen)
  if not bucket then return end
  for request in pairs(bucket.items) do
    if request.pending and not seen[request] then seen[request] = true; out[#out + 1] = request end
  end
end

local function row_description(request)
  local frontier = request and request._proof
  if frontier and frontier.complete then return frontier, false end
  local shape, lifetime = potential_shape(request)
  return shape or frontier or { exchanges = {}, locations = {}, resources = {}, dynamic = true }, true, lifetime
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
  if bucket then snapshot.buckets[bucket] = bucket.generation end
end

local function add_location(snapshot, location, version)
  if location and snapshot.locations[location] == nil then snapshot.locations[location] = version or location.version or 0 end
end

local function add_request(snapshot, request)
  if request then snapshot.requests[request] = request.op end
end

function M.acknowledge(engine, state)
  local value = engine.proof_graph
  if not value then return end
  for _, root in pairs((state and state.roots) or EMPTY) do value.dirty[root.request] = nil end
end

function M.capture(engine, state, certificate, frontiers)
  local value = M.ensure(engine)
  local snapshot = { requests = {}, locations = {}, buckets = {}, checks = {}, timers = {} }
  for _, root in pairs(state.roots or EMPTY) do add_request(snapshot, root.request) end
  for location, version in pairs((state.journal and state.journal.observed) or EMPTY) do
    add_location(snapshot, location, version)
  end

  local demanded = {}
  local function add_exchange(resource, role)
    local roles = demanded[resource]
    if not roles then roles = {}; demanded[resource] = roles end
    if roles[role] then return end
    roles[role] = true
    local possible = value.potential_exchange[resource]
    add_bucket(snapshot, possible and possible[opposite(role)])
  end
  local function add_fact(fact)
    local kind = fact.kind
    if kind == 'frontier-exchange' or kind == 'latent-frontier-exchange' then
      add_exchange(fact.resource, fact.role)
    elseif kind == 'frontier-location' then
      add_location(snapshot, fact.location, fact.version); add_bucket(snapshot, value.potential_location[fact.location])
    elseif kind == 'frontier-resource' then
      add_bucket(snapshot, value.potential_resource[fact.resource])
    elseif kind == 'latent-frontier-location' then
      add_bucket(snapshot, value.potential_location[fact.location])
    elseif kind == 'latent-frontier-resource' then
      add_bucket(snapshot, value.potential_resource[fact.resource])
    elseif kind == 'check' and fact.value then
      snapshot.checks[#snapshot.checks + 1] = fact.value
    elseif kind == 'interest' then
      local interest = fact.value
      if interest and interest.kind == 'timer' and type(interest.deadline) == 'number' then snapshot.timers[#snapshot.timers + 1] = interest.deadline end
    end
  end

  if frontiers then
    for _, frontier in pairs(frontiers) do
      for i = 1, #(frontier.certificate or EMPTY) do add_fact(frontier.certificate[i]) end
    end
  else
    for i = 1, #(state.intents or EMPTY) do
      local intent = state.intents[i]
      if intent.active then
        if intent.kind == 'exchange' then
          add_exchange(intent.resource, intent.role)
        elseif intent.spec and intent.spec.location then
          add_location(snapshot, intent.spec.location, intent.observed_version)
          add_bucket(snapshot, value.potential_location[intent.spec.location])
        end
        local check = intent.absence_check
        if type(check) == 'function' then check = { validate = check } end
        if check then snapshot.checks[#snapshot.checks + 1] = check end
        local interest = intent.interest
        if interest and interest.kind == 'timer' and type(interest.deadline) == 'number' then snapshot.timers[#snapshot.timers + 1] = interest.deadline end
      end
    end
  end
  for i = 1, #(certificate or EMPTY) do add_fact(certificate[i]) end
  return snapshot
end

function M.valid(engine, snapshot)
  local value = engine.proof_graph
  if not snapshot then return false, 'missing-frontier-snapshot' end
  for request, op in pairs(snapshot.requests or EMPTY) do
    if not request.pending or request.op ~= op then return false, 'request' end
    if value and value.dirty[request] then return false, 'frontier-dirty' end
  end
  for location, version in pairs(snapshot.locations or EMPTY) do
    if (location.version or 0) ~= version then return false, 'location-version' end
  end
  for bucket, generation in pairs(snapshot.buckets or EMPTY) do
    if bucket.generation ~= generation then return false, 'frontier-bucket' end
  end
  for i = 1, #(snapshot.checks or EMPTY) do
    local check = snapshot.checks[i]
    if type(check.validate) == 'function' and not check.validate(engine.runtime, check) then return false, 'frontier-check' end
  end
  local now
  for i = 1, #(snapshot.timers or EMPTY) do
    now = now or engine.runtime:now()
    if now >= snapshot.timers[i] then return false, 'timer' end
  end
  return true
end

function M.retry(engine, request)
  local value = engine.proof_graph
  local frontier = request and request._proof
  if not frontier or not frontier.retry or (value and value.dirty[request]) then return nil end
  if not M.valid(engine, frontier.snapshot) then return nil end
  return M.copy(frontier.certificate)
end

return M
