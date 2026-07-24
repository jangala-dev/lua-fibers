-- Tagged facts shared by live retry, fallback and retained-proof validation.
--
-- A certificate is one ordered fact list.  Live search contributes interests,
-- checks and activation identity; retention adds policy, membership, version and
-- deadline facts.  Consumers use this module rather than depending on storage
-- fields or maintaining parallel proof representations.

local IR = require('fibers.internal.kernel.ir')

local M = {}

local LOCAL = 'local-absence'
local DURABLE = 'durable-retry'

M.LOCAL = LOCAL
M.DURABLE = DURABLE

local function identity(fact)
  if fact.identity ~= nil then
    return fact.identity
  end
  if fact.kind == 'interest' or fact.kind == 'check' then
    local value = fact.value
    return value and (value.id or value) or false
  end
  if fact.kind == 'activation' then
    return fact.value
  end
  if fact.kind == 'request' then
    return fact.id
  end
  if fact.kind == 'policy' then
    return 'policy'
  end
  return fact.object or fact.id or fact.value or false
end

local function same_fact(left, right)
  return left.kind == right.kind and identity(left) == identity(right)
end

local function add_unique(certificate, fact)
  local facts = certificate.facts
  for i = 1, #facts do
    if same_fact(facts[i], fact) then
      return false
    end
  end
  facts[#facts + 1] = fact
  return true
end

function M.new(scope)
  scope = scope or LOCAL
  if scope ~= LOCAL and scope ~= DURABLE then
    error('unknown certificate scope: ' .. tostring(scope), 2)
  end
  return { scope = scope, facts = {} }
end

function M.local_absence()
  return M.new(LOCAL)
end

function M.durable_retry()
  return M.new(DURABLE)
end

function M.is_local(certificate)
  return certificate ~= nil and (certificate.scope or LOCAL) == LOCAL
end

function M.is_durable(certificate)
  return certificate ~= nil and certificate.scope == DURABLE
end

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
  local out = M.new(certificate.scope or LOCAL)
  out.failure_task_id = certificate.failure_task_id
  for i = 1, #(certificate.facts or {}) do
    out.facts[i] = certificate.facts[i]
  end
  return out
end

function M.merge(dst, src)
  if not src then
    return dst
  end
  dst = dst or M.new(src.scope or LOCAL)
  if (dst.scope or LOCAL) ~= (src.scope or LOCAL) then
    -- A mixture of branch-local and durable facts is branch-local until the
    -- runtime explicitly captures it against the managed world.
    dst.scope = LOCAL
  end
  local failure_task_id = src.failure_task_id
  if failure_task_id ~= nil then
    if dst.failure_task_id == nil then
      dst.failure_task_id = failure_task_id
    elseif dst.failure_task_id ~= failure_task_id then
      dst.failure_task_id = false
    end
  end
  for i = 1, #(src.facts or {}) do
    add_unique(dst, src.facts[i])
  end
  return dst
end

function M.merge_all(values)
  local out
  for i = 1, #(values or {}) do
    out = M.merge(out, values[i])
  end
  return out or M.new()
end

function M.each(certificate, kind, fn)
  for i = 1, #((certificate and certificate.facts) or {}) do
    local fact = certificate.facts[i]
    if fact.kind == kind then
      fn(fact.value, fact)
    end
  end
end

function M.values(certificate, kind)
  local out = {}
  M.each(certificate, kind, function(value)
    out[#out + 1] = value
  end)
  return out
end

function M.mark_failure(certificate, task_id)
  certificate = certificate or M.local_absence()
  if certificate.failure_task_id == nil then
    certificate.failure_task_id = task_id
  elseif certificate.failure_task_id ~= task_id then
    certificate.failure_task_id = false
  end
  return certificate
end

function M.local_failure_task(certificate)
  local task_id = certificate and certificate.failure_task_id or nil
  if not task_id then
    return nil
  end
  for i = 1, #((certificate and certificate.facts) or {}) do
    if certificate.facts[i].kind ~= 'activation' then
      return nil
    end
  end
  return task_id
end

function M.gate_epoch(certificate)
  -- Gate identity is the canonical epoch of the atomic observations which
  -- opened a fallback.  It is independent of fact order and certificate table
  -- identity, but changes when a relevant negative observation changes.
  local keys = M.values(certificate, 'activation')
  table.sort(keys)
  return #keys > 0 and table.concat(keys, '|') or '-'
end

function M.new_absence_gate()
  return { checks = {} }
end

function M.stamp_absence_gate(gate, runtime)
  if gate then
    gate.epoch = runtime.epoch
    gate.pending_generation = runtime.pending_generation
  end
  return gate
end

function M.validate_absence_gate(gate, runtime)
  if not gate then
    return true
  end
  if runtime.epoch ~= gate.epoch then
    return false, 'stale-negative-epoch'
  end
  if runtime.pending_generation ~= gate.pending_generation then
    return false, 'stale-negative-frontier'
  end
  for i = 1, #(gate.checks or {}) do
    local check = gate.checks[i]
    if check and type(check.validate) == 'function' and not check.validate(runtime, check) then
      return false, 'stale-negative-check'
    end
  end
  return true
end

function M.from_intents(intents)
  local certificate = M.local_absence()
  local activation = {}
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    if intent.interest then
      M.add(certificate, 'interest', { value = intent.interest })
      activation[#activation + 1] = 'i:' .. tostring(intent.interest.id or intent.interest)
    end

    local check = intent.absence_check
    if type(check) == 'function' then
      check = { validate = check, id = 'absence:' .. tostring(intent.id) }
    elseif not check and intent.program and intent.program.location then
      local location = intent.program.location
      local version = intent.program.observed_version or location.version
      check = {
        id = 'location:' .. tostring(location.id) .. ':' .. tostring(version),
        validate = function()
          return location.version == version
        end,
      }
    end
    if check then
      M.add(certificate, 'check', { value = check })
      activation[#activation + 1] = 'c:' .. tostring(check.id or check)
    end
  end
  table.sort(activation)
  M.add(certificate, 'activation', {
    value = #activation > 0 and table.concat(activation, ',') or '-',
  })
  return certificate
end

local function ordered_objects(values)
  local out = {}
  for value in pairs(values or {}) do
    out[#out + 1] = value
  end
  table.sort(out, function(left, right)
    local li, ri = left.id or left._fibers_id, right.id or right._fibers_id
    if li ~= nil and ri ~= nil and li ~= ri then
      return tostring(li) < tostring(ri)
    end
    return tostring(left) < tostring(right)
  end)
  return out
end

function M.capture(runtime, requests, component, source)
  if not runtime.dependency_index then
    return nil, 'dependency-index-disabled'
  end

  local certificate = M.durable_retry()
  for i = 1, #((source and source.facts) or {}) do
    add_unique(certificate, source.facts[i])
  end
  M.add(certificate, 'policy', {
    machine = runtime.machine_name,
    branch = runtime.branch_policy,
    normalise = runtime.normalise_search ~= false,
    symmetry = runtime.certified_symmetry ~= false,
  })

  local locations, resources = {}, {}
  local has_external = false
  local precise_external = source ~= nil

  if component and component.dynamic and component.dynamic > 0 then
    M.add(certificate, 'runtime-epoch', { object = runtime, value = runtime.epoch })
  end

  for i = 1, #((component and component.dependencies) or {}) do
    local dependency = component.dependencies[i]
    M.add(certificate, 'bucket', { object = dependency, value = dependency.generation or 0 })
  end

  local ids = component and component.ids
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
    local metadata = request.metadata or IR.metadata(request.op)
    request.metadata = metadata
    has_external = has_external or metadata.external == true
    M.add(certificate, 'request', { id = id, object = request, op = request.op })
    for location in pairs(metadata.locations or {}) do
      locations[location] = true
    end
    for resource in pairs(metadata.resources or {}) do
      resources[resource] = true
    end
  end

  M.each(source, 'interest', function(interest)
    if interest and interest.kind == 'timer' and type(interest.deadline) == 'number' then
      M.add(certificate, 'timer', {
        identity = interest,
        object = interest.resource or runtime,
        value = interest.deadline,
      })
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
  end)

  if has_external and not precise_external then
    M.add(certificate, 'external-generation', {
      object = runtime,
      value = runtime.external_generation or 0,
    })
  end

  local ordered_locations = ordered_objects(locations)
  for i = 1, #ordered_locations do
    local location = ordered_locations[i]
    M.add(certificate, 'location', { object = location, value = location.version or 0 })
  end

  local ordered_resources = ordered_objects(resources)
  for i = 1, #ordered_resources do
    local resource = ordered_resources[i]
    if type(resource.version) ~= 'number' then
      return nil, 'unversioned-resource'
    end
    M.add(certificate, 'resource', { object = resource, value = resource.version })
  end

  return certificate
end

function M.valid(certificate, runtime)
  if not certificate then
    return false, 'missing'
  end
  if not M.is_durable(certificate) then
    return false, 'local-absence'
  end
  local membership_reason
  for i = 1, #(certificate.facts or {}) do
    local fact = certificate.facts[i]
    if fact.kind == 'policy' then
      if
        fact.machine ~= runtime.machine_name
        or fact.branch ~= runtime.branch_policy
        or fact.normalise ~= (runtime.normalise_search ~= false)
        or fact.symmetry ~= (runtime.certified_symmetry ~= false)
      then
        return false, 'policy'
      end
    elseif fact.kind == 'request' then
      if runtime.pending_by_id[fact.id] ~= fact.object or fact.object.op ~= fact.op then
        membership_reason = membership_reason or 'request'
      end
    elseif fact.kind == 'bucket' then
      if fact.object.generation ~= fact.value then
        membership_reason = membership_reason or 'bucket'
      end
    elseif fact.kind == 'external-generation' then
      if (runtime.external_generation or 0) ~= fact.value then
        return false, 'external-generation'
      end
    elseif fact.kind == 'timer' then
      if runtime:now() >= fact.value then
        return false, 'timer'
      end
    elseif fact.kind == 'runtime-epoch' then
      if runtime.epoch ~= fact.value then
        return false, 'runtime-epoch'
      end
    elseif fact.kind == 'location' or fact.kind == 'resource' then
      if fact.object.version ~= fact.value then
        return false, fact.kind
      end
    elseif fact.kind ~= 'interest' and fact.kind ~= 'check' and fact.kind ~= 'activation' then
      return false, 'unknown-fact'
    end
  end
  if membership_reason then
    return false, membership_reason
  end
  return true
end

return M
