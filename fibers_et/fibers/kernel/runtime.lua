-- Open-world fibre scheduler and commit driver.

local Op = require('fibers.atoms.op')
local Store = require('fibers.kernel.store')
local Interest = require('fibers.interest')
local ExternalFeed = require('fibers.external_feed')
local Protected = require('fibers.internal.protected')
local Machine = require('fibers.kernel.machine')
local IR = require('fibers.kernel.ir')
local Instrumentation = require('fibers.kernel.instrumentation')
local DependencyIndex = require('fibers.kernel.dependency_index')

local Runtime = {}

local function select_machine(opts)
  local requested = opts.machine
  if requested == nil and os and os.getenv then requested = os.getenv('FIBERS_MACHINE') end
  if requested == 'reference' then
    return require('fibers.internal.reference_machine'), 'reference'
  end
  return Machine, 'trail'
end
Runtime.__index = Runtime
local CURRENT_RUNTIME = nil
local CURRENT_SCOPE = nil
function Runtime.current() return CURRENT_RUNTIME end
function Runtime.current_scope() return CURRENT_SCOPE end

local unpack_ = table.unpack or unpack
local pack_ = Op._pack
local function unpack_pack(p) return unpack_(p, 1, p.n or #p) end

local function merge_effects(effects)
  local order, by_key = {}, {}
  for i = 1, #effects do
    local effect = effects[i]
    local kind = effect.kind
    local key = tostring(kind._fibers_kind_id or kind.name) .. '\0' .. tostring(kind.key(effect.payload))
    local old = by_key[key]
    if old then
      local payload, err = kind.merge(old.payload, effect.payload)
      if not payload then return nil, err end
      old.payload = payload
    else
      local copy = { _fibers_effect = true, kind = kind, payload = effect.payload }
      by_key[key] = copy
      order[#order + 1] = key
    end
  end
  local out = {}
  for i = 1, #order do out[i] = by_key[order[i]] end
  return out
end

local Cancellation = {}
Cancellation.__index = Cancellation
Cancellation.__tostring = function(e) return e.message or 'fiber cancelled' end
function Runtime.cancelled(reason, token)
  return setmetatable({ _fibers_cancelled = true, reason = reason, token = token,
    message = reason and tostring(reason) or 'fiber cancelled' }, Cancellation)
end
function Runtime.is_cancelled(e) return type(e) == 'table' and e._fibers_cancelled == true end

local RuntimeError = {}
RuntimeError.__index = RuntimeError
RuntimeError.__tostring = function(e) return e.message or tostring(e.cause) end

function Runtime:_make_error(kind, err, fields)
  fields = fields or {}
  local out = {
    _fibers_error = true,
    kind = kind,
    phase = fields.phase or self._phase,
    action = fields.action,
    committed = fields.committed,
    message = fields.message or tostring(err),
    cause = err,
  }
  return setmetatable(out, RuntimeError)
end

function Runtime:_throw_error(e, level)
  self._driver_depth = 0
  error(e, level or 0)
end

function Runtime:_fail(kind, err, fields)
  local e = self:_make_error(kind, err, fields)
  return self:_throw_error(e, fields and fields.level or 0)
end

function Runtime:_fatal(kind, err, fields)
  fields = fields or {}
  local e = self:_make_error(kind, err, fields)
  e.fatal = true
  self._failed = e
  return self:_throw_error(e, fields.level or 0)
end

function Runtime:failed() return self._failed end
function Runtime:_check_not_failed(level) if self._failed then error(self._failed, level or 0) end end

function Runtime:_is_current_fiber()
  local f = self._current_fiber
  if not f then return false end
  -- Yieldable protected calls may execute user code in a child coroutine.
  -- Resolve that child back to the owning runtime fibre before enforcing the
  -- perform/driver phase boundary.
  local running = Protected.running(coroutine.running())
  return running == f.co
end

function Runtime:_require_perform_allowed(level)
  if self:_is_current_fiber() and self._phase == 'fiber' then return true end
  return self:_fail('phase_error', 'perform may only be called by the currently resumed runtime fibre', {
    action = 'perform', phase = self._phase, level = level or 0,
  })
end

function Runtime:_require_spawn_allowed(level)
  if self._phase == 'external' or self._phase == 'fiber' then return true end
  return self:_fail('phase_error', 'spawn may not be called from runtime internals', {
    action = 'spawn', phase = self._phase, level = level or 0,
  })
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fiber() and self._phase == 'external' then return true end
  return self:_fail('phase_error', tostring(action) .. ' may only be called by external driver code', {
    action = action, phase = self._phase, level = level or 0,
  })
end

local function finish_phase_call(self, old_phase, name, kind, fatal, committed, ok, ...)
  self._phase = old_phase
  if ok then return ... end
  local err = ...
  if type(err) == 'table' and err._fibers_error and not fatal then error(err, 0) end
  if fatal then return self:_fatal(kind or 'effect_error', err, { phase = name, committed = committed, level = 0 }) end
  return self:_fail(kind or 'callback_error', err, { phase = name, level = 0 })
end

function Runtime:_set_phase(name) local old = self._phase; self._phase = name; return old end
function Runtime:_restore_phase(old) self._phase = old end
function Runtime:_call_in_phase(name, kind, fn, ...)
  local old = self:_set_phase(name)
  return finish_phase_call(self, old, name, kind, false, nil, pcall(fn, ...))
end
function Runtime:_call_fatal_in_phase(name, kind, committed, fn, ...)
  local old = self:_set_phase(name)
  return finish_phase_call(self, old, name, kind, true, committed, pcall(fn, ...))
end

function Runtime.new(opts)
  opts = opts or {}
  local machine, machine_name = select_machine(opts)
  local instrumentation = nil
  if opts.instrumentation then instrumentation = Instrumentation.new(opts.instrumentation) end
  local dependency_index_threshold = math.max(1, math.floor(opts.dependency_index_threshold or 16))
  local dependency_index_release_threshold = math.max(0, math.floor(opts.dependency_index_release_threshold
    or math.floor(dependency_index_threshold / 2)))
  if dependency_index_release_threshold >= dependency_index_threshold then
    dependency_index_release_threshold = math.max(0, dependency_index_threshold - 1)
  end
  return setmetatable({
    opts = opts,
    host = opts.host or {},
    _phase = 'external',
    _driver_depth = 0,
    _failed = nil,
    quiet_deadlock = opts.quiet_deadlock == true,
    search_limit = opts.search_limit or 1000000,
    choice_seed = opts.choice_seed or 1,
    _ready_fibers = {},
    _ready_head = 1,
    _ready_tail = 0,
    _live_fibers = 0,
    pending = {},
    pending_by_id = {},
    dependency_index = opts.dependency_index == false and nil or DependencyIndex.new(),
    dependency_index_threshold = dependency_index_threshold,
    dependency_index_release_threshold = dependency_index_release_threshold,
    _dependency_index_active = opts.dependency_index ~= false and dependency_index_threshold <= 1,
    component_search = opts.component_search ~= false,
    normalise_search = opts.normalise_search ~= false,
    branch_policy = opts.branch_policy or 'constrained',
    verify_dependencies = opts.verify_dependencies == true,
    next_fiber = 0,
    next_request = 0,
    pending_generation = 0,
    epoch = 0,
    _last_search_steps = 0,
    _plan_observations = {},
    _external_feeds = setmetatable({}, { __mode = 'kv' }),
    machine = machine,
    machine_name = machine_name,
    instrumentation = instrumentation,
    stats = {
      plans = 0,
      search_calls = 0,
      state_clones = 0,
      validation_failures = 0,
      refreshes = 0,
      commits = 0,
      fallback_commits = 0,
      trail_entries = 0,
      rollbacks = 0,
    },
  }, Runtime)
end

function Runtime:instrumentation_snapshot()
  if not self.instrumentation then return nil end
  return self.instrumentation:snapshot()
end

function Runtime:reset_instrumentation()
  if self.instrumentation then self.instrumentation:reset() end
  self._plan_observations = {}
  return self
end

function Runtime:push_scope(scope)
  local fiber = self._current_fiber
  if not fiber then error('Runtime:push_scope requires current fibre', 2) end
  fiber.scope_stack = fiber.scope_stack or {}
  fiber.scope_stack[#fiber.scope_stack + 1] = scope
  fiber.scope = scope
  CURRENT_SCOPE = scope
  return { fiber = fiber, depth = #fiber.scope_stack, scope = scope }
end

function Runtime:pop_scope(token)
  local fiber = self._current_fiber
  if not token or token.fiber ~= fiber then error('Runtime:pop_scope token mismatch', 2) end
  local stack = fiber.scope_stack or {}
  if #stack ~= token.depth or stack[#stack] ~= token.scope then error('Runtime:pop_scope stack mismatch', 2) end
  stack[#stack] = nil
  fiber.scope = stack[#stack]
  CURRENT_SCOPE = fiber.scope
  return true
end

function Runtime:with_scope(scope, fn, ...)
  local token = self:push_scope(scope)
  local packed = pack_(Protected.pcall(fn, ...))
  local ok = packed[1]
  self:pop_scope(token)
  if not ok then error(packed[2], 0) end
  return unpack_(packed, 2, packed.n)
end

function Runtime:now()
  local now = self.host and self.host.now
  if type(now) == 'function' then return now(self) end
  return 0
end

function Runtime:external_feed(resource)
  return ExternalFeed.for_resource(self, resource)
end

function Runtime:deliver(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('external delivery', 2)
  if not ExternalFeed.is_feed(feed) then error('Runtime:deliver expects an ExternalFeed', 2) end
  if feed.runtime ~= self then error('external feed belongs to another runtime', 2) end
  feed:_deliver(...)
  self.epoch = self.epoch + 1
  return feed.resource
end

function Runtime:clear_external(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('clear external resource', 2)
  if not ExternalFeed.is_feed(feed) then error('Runtime:clear_external expects an ExternalFeed', 2) end
  if feed.runtime ~= self then error('external feed belongs to another runtime', 2) end
  feed:_clear(...)
  self.epoch = self.epoch + 1
  return feed.resource
end

function Runtime:signal(name)
  local resource = require('fibers.atoms.signal').new(name)
  return resource, self:external_feed(resource)
end

function Runtime:events(name)
  local resource = require('fibers.atoms.event_queue').new(name)
  return resource, self:external_feed(resource)
end

function Runtime:readiness(key, name)
  local resource = require('fibers.atoms.readiness').new(key, nil, name)
  return resource, self:external_feed(resource)
end

local function spawn_unchecked(self, fn, name, scope)
  if type(fn) ~= 'function' then error('spawn expects a function', 3) end
  self.next_fiber = self.next_fiber + 1
  local fiber = {
    id = self.next_fiber,
    name = name or ('fiber-' .. tostring(self.next_fiber)),
    co = coroutine.create(fn),
    started = false,
    done = false,
    scope = scope,
    scope_stack = scope and { scope } or {},
  }
  self._ready_tail = self._ready_tail + 1
  self._ready_fibers[self._ready_tail] = fiber
  self._live_fibers = self._live_fibers + 1
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibres_spawned')
    instrumentation:max('live_fibres', self._live_fibers)
    instrumentation:max('ready_fibres', self._ready_tail - self._ready_head + 1)
  end
  return fiber
end

function Runtime:spawn_raw(fn, name, scope)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  return spawn_unchecked(self, fn, name, scope)
end

function Runtime:_spawn_committed(fn, name, scope)
  self:_check_not_failed(2)
  return spawn_unchecked(self, fn, name, scope)
end

function Runtime:_discharge_interrupt(token, reason)
  local Interrupt = require('fibers.internal.interrupt')
  Interrupt.raise(token, reason)
  local ids, requests = {}, {}
  for i = 1, #self.pending do
    local req = self.pending[i]
    if req.interrupt == token then ids[#ids + 1] = req.id; requests[#requests + 1] = req end
  end
  if #ids > 0 then self:_remove_pending(ids) end
  for i = 1, #requests do
    self:_resume_fiber(requests[i].fiber, { cancelled = Runtime.cancelled(reason, token) })
  end
  return true
end

function Runtime:perform(op, opts)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  if not Op.is_op(op) then error('perform expects an Op', 2) end
  opts = opts or {}
  if opts.interrupt and opts.interrupt.raised and not opts.masked then
    error(Runtime.cancelled(opts.interrupt.reason, opts.interrupt), 0)
  end
  local response = coroutine.yield({ _fibers_perform = true, op = op, opts = opts })
  if response and response.cancelled then error(response.cancelled, 0) end
  local packed = response.pack
  if response.wrap then packed = response.wrap(packed) end
  return unpack_pack(packed)
end

function Runtime:_rebuild_dependency_index()
  if not self.dependency_index then return end
  self.dependency_index = DependencyIndex.new()
  for i = 1, #self.pending do self.dependency_index:add(self.pending[i]) end
  self._dependency_index_active = true
  if self.instrumentation then self.instrumentation:inc('dependency_index_activations') end
end

function Runtime:_deactivate_dependency_index()
  if not self.dependency_index then return end
  self.dependency_index = DependencyIndex.new()
  self._dependency_index_active = false
  if self.instrumentation then self.instrumentation:inc('dependency_index_deactivations') end
end

function Runtime:_add_pending(fiber, yielded)
  self.next_request = self.next_request + 1
  local metadata = self.instrumentation and IR.metadata(yielded.op) or nil
  local request = {
    id = self.next_request,
    fiber = fiber,
    op = yielded.op,
    metadata = metadata,
    footprint = metadata,
    memo = {},
    interrupt = yielded.opts and yielded.opts.interrupt or nil,
  }
  self.pending[#self.pending + 1] = request
  self.pending_by_id[request.id] = request
  if self.dependency_index then
    if self._dependency_index_active then
      self.dependency_index:add(request)
    elseif #self.pending >= self.dependency_index_threshold then
      self:_rebuild_dependency_index()
    end
  end
  self.pending_generation = self.pending_generation + 1
  local instrumentation = self.instrumentation
  if instrumentation then
    metadata = request.metadata or metadata or IR.metadata(yielded.op)
    request.metadata, request.footprint = metadata, metadata
    instrumentation:inc('perform_yields')
    instrumentation:max('pending_requests', #self.pending)
    if metadata.dynamic then instrumentation:inc('requests_dynamic')
    else instrumentation:inc('requests_analysable') end
    instrumentation:inc('operation_nodes', metadata.nodes or 0)
    instrumentation:max('operation_nodes_per_request', metadata.nodes or 0)
    instrumentation:observe('operation_nodes_per_request', metadata.nodes or 0)
    local exchanges, locations, resources = IR.metadata_counts(metadata)
    instrumentation:inc('dependency_exchange_resources', exchanges)
    instrumentation:inc('dependency_locations', locations)
    instrumentation:inc('dependency_wide_resources', resources)
    instrumentation:max('dependency_exchange_resources_per_request', exchanges)
    instrumentation:max('dependency_locations_per_request', locations)
    instrumentation:max('dependency_wide_resources_per_request', resources)
  end
end

function Runtime:_finish_fiber(fiber)
  if fiber.done then return end
  fiber.done = true
  -- A completed fibre handle remains useful for identity and diagnostics, but
  -- its coroutine and dynamic scope graph must not be retained by the runtime.
  fiber.co = nil
  fiber.scope = nil
  fiber.scope_stack = nil
  self._live_fibers = math.max(self._live_fibers - 1, 0)
  local instrumentation = self.instrumentation
  if instrumentation then instrumentation:inc('fibres_completed') end
end

function Runtime:_resume_fiber(fiber, value)
  local ok, yielded
  local instrumentation = self.instrumentation
  local resume_started = instrumentation and instrumentation.clock() or nil
  if instrumentation then instrumentation:inc('fibre_resumes') end
  local previous, previous_scope, previous_fiber = CURRENT_RUNTIME, CURRENT_SCOPE, self._current_fiber
  self._current_fiber = fiber
  CURRENT_RUNTIME, CURRENT_SCOPE = self, fiber.scope
  local old_phase = self:_set_phase('fiber')
  if fiber.started then
    ok, yielded = coroutine.resume(fiber.co, value)
  else
    fiber.started = true
    ok, yielded = coroutine.resume(fiber.co)
  end
  self:_restore_phase(old_phase)
  if instrumentation then
    instrumentation:inc('fibre_cpu_ns', math.floor((instrumentation.clock() - resume_started) * 1000000000 + 0.5))
  end
  CURRENT_RUNTIME, CURRENT_SCOPE = previous, previous_scope
  self._current_fiber = previous_fiber
  if not ok then
    self:_finish_fiber(fiber)
    error(yielded, 0)
  end
  if coroutine.status(fiber.co) == 'dead' then
    self:_finish_fiber(fiber)
    return
  end
  if type(yielded) ~= 'table' or yielded._fibers_perform ~= true then
    self:_finish_fiber(fiber)
    error('runtime received an unsupported coroutine yield', 0)
  end
  self:_add_pending(fiber, yielded)
end

function Runtime:_remove_pending(ids)
  local remove = {}
  for i = 1, #ids do remove[ids[i]] = true end
  local kept = {}
  for i = 1, #self.pending do
    local request = self.pending[i]
    if remove[request.id] then
      if self.dependency_index and self._dependency_index_active then self.dependency_index:remove(request) end
      self.pending_by_id[request.id] = nil
    else
      kept[#kept + 1] = request
    end
  end
  self.pending = kept
  if self.dependency_index and self._dependency_index_active and #kept < self.dependency_index_release_threshold then
    self:_deactivate_dependency_index()
  end
  self.pending_generation = self.pending_generation + 1
  local instrumentation = self.instrumentation
  if instrumentation then instrumentation:inc('pending_removed', #ids) end
end

function Runtime:_component_requests(focus_id)
  if not self.pending_by_id[focus_id] then return {}, self.instrumentation and { total = 0, size = 0 } or nil end
  if not self.component_search or not self.dependency_index or not self._dependency_index_active then
    if not self.instrumentation then return self.pending_by_id, nil end
    local total, ids = #self.pending, {}
    for id in pairs(self.pending_by_id) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for i = 1, #ids do parts[i] = tostring(ids[i]) end
    return self.pending_by_id, {
      total = total, size = total, global = true, disabled = true,
      ids = ids, signature = table.concat(parts, ','),
    }
  end
  return self.dependency_index:component(focus_id, self.pending_by_id, self.instrumentation ~= nil)
end

function Runtime:_has_supplier(intents, entered, excluded, requests)
  requests = requests or self.pending_by_id
  if self.dependency_index and self._dependency_index_active then
    return self.dependency_index:supplier_ids(intents, requests, entered, excluded)[1] ~= nil
  end
  for id, request in pairs(requests) do
    if not (entered and entered[id]) and not (excluded and excluded[id]) then
      local metadata = request.metadata or request.footprint or IR.metadata(request.op)
      request.metadata, request.footprint = metadata, metadata
      local can_supply = IR.footprint_may_supply(metadata, intents)
      if can_supply then return true end
    end
  end
  return false
end

function Runtime:_supplier_request_rows(intents, entered, excluded, requests)
  requests = requests or self.pending_by_id
  if self.dependency_index and self._dependency_index_active then
    return self.dependency_index:supplier_ids(intents, requests, entered, excluded)
  end
  local rows = {}
  for id, request in pairs(requests) do
    if not (entered and entered[id]) and not (excluded and excluded[id]) then
      local metadata = request.metadata or request.footprint or IR.metadata(request.op)
      request.metadata, request.footprint = metadata, metadata
      local score, reason = IR.supply_score(metadata, intents)
      if score > 0 then rows[#rows + 1] = { id = id, score = score, reason = reason } end
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)
  return rows
end

function Runtime:_find_candidate_impl(focus_id, search_limit)
  if not self.pending_by_id[focus_id] then return nil end
  local requests, component = self:_component_requests(focus_id)
  local instrumentation = self.instrumentation
  if instrumentation then
    component = component or { total = #self.pending, size = #self.pending, global = true }
    local previous = self._plan_observations[focus_id]
    if previous then
      instrumentation:inc('plan_revisits')
      if previous.signature == component.signature then instrumentation:inc('plan_same_component')
      else instrumentation:inc('plan_component_changed') end
      if previous.epoch == self.epoch then instrumentation:inc('plan_same_epoch')
      else instrumentation:inc('plan_epoch_changed') end
      if previous.pending_generation == self.pending_generation then instrumentation:inc('plan_same_frontier')
      else instrumentation:inc('plan_frontier_changed') end
      if previous.signature == component.signature and previous.epoch == self.epoch
          and previous.pending_generation == self.pending_generation then
        instrumentation:inc('plan_reuse_eligible')
      end
      local intersection = 0
      local prior_ids = previous.ids or {}
      local current = {}
      for i = 1, #(component.ids or {}) do current[component.ids[i]] = true end
      for i = 1, #prior_ids do if current[prior_ids[i]] then intersection = intersection + 1 end end
      local union = #prior_ids + #(component.ids or {}) - intersection
      instrumentation:observe('component_overlap_percent', union > 0 and intersection * 100 / union or 100)
    end
    self._plan_observations[focus_id] = {
      signature = component.signature,
      ids = component.ids,
      epoch = self.epoch,
      pending_generation = self.pending_generation,
    }
  end
  return self.machine.search(self, requests, focus_id, search_limit, component)
end

function Runtime:_find_candidate(focus_id, search_limit)
  return self:_call_in_phase('search', 'search_error', function()
    return self:_find_candidate_impl(focus_id, search_limit)
  end)
end

function Runtime:_validate(candidate)
  for i = 1, #candidate.participants do
    if not self.pending_by_id[candidate.participants[i]] then return false, 'participant-changed' end
  end
  local valid, validity_err = Store.validate(candidate.observations)
  if not valid then return false, validity_err end
  if candidate.negative_guard then
    if self.epoch ~= candidate.epoch then return false, 'stale-negative-epoch' end
    if self.pending_generation ~= candidate.pending_generation then return false, 'stale-negative-frontier' end
    for i = 1, #(candidate.negative_checks or {}) do
      local check = candidate.negative_checks[i]
      if check and type(check.validate) == 'function' and not check.validate(self, check) then
        return false, 'stale-negative-check'
      end
    end
  end
  return true
end

function Runtime:_prepare_effects(candidate)
  local effects, merge_err = merge_effects(candidate.effects)
  if not effects then return nil, merge_err end
  local prepared = {}
  for i = 1, #effects do
    local effect = effects[i]
    local p, err = self:_call_in_phase('effect_prepare', 'effect_error', effect.kind.prepare, self, effect.payload)
    if not p then return nil, err end
    prepared[#prepared + 1] = p
  end
  return prepared
end

function Runtime:_commit(candidate)
  local instrumentation = self.instrumentation
  local commit_started = instrumentation and instrumentation.clock() or nil
  local valid, validation_reason = self:_validate(candidate)
  if not valid then
    self.stats.validation_failures = self.stats.validation_failures + 1
    if instrumentation then
      instrumentation:inc('validation_failures')
      instrumentation:inc('validation_failure_' .. tostring(validation_reason or 'unknown'))
      instrumentation:inc('commit_cpu_ns', math.floor((instrumentation.clock() - commit_started) * 1000000000 + 0.5))
    end
    return false, 'stale'
  end

  local prepared = candidate.prepared_effects
  if not prepared then
    local err
    prepared, err = self:_prepare_effects(candidate)
    if not prepared then return false, err or 'effect-prepare-refused' end
  end

  local requests = {}
  for i = 1, #candidate.participants do
    local id = candidate.participants[i]
    requests[i] = self.pending_by_id[id]
  end

  Store.commit(candidate.writes)
  self.epoch = self.epoch + 1
  self.stats.commits = self.stats.commits + 1
  if candidate.negative_guard then self.stats.fallback_commits = self.stats.fallback_commits + 1 end
  if instrumentation then
    instrumentation:inc('commits')
    instrumentation:inc('commit_participants', #candidate.participants)
    local write_count = 0
    for _ in pairs(candidate.writes or {}) do write_count = write_count + 1 end
    instrumentation:inc('commit_writes', write_count)
    instrumentation:inc('commit_effects', #prepared)
    instrumentation:observe('participants_per_commit', #candidate.participants)
    instrumentation:observe('writes_per_commit', write_count)
  end

  self:_remove_pending(candidate.participants)

  for i = 1, #prepared do
    local p = prepared[i]
    self:_call_fatal_in_phase('effect_discharge', 'effect_error', true, p.discharge, self, p, nil)
  end

  for i = 1, #requests do
    local request = requests[i]
    local outcome = candidate.outcomes[request.id]
    self:_resume_fiber(request.fiber, outcome)
  end
  if instrumentation then
    instrumentation:inc('commit_cpu_ns', math.floor((instrumentation.clock() - commit_started) * 1000000000 + 0.5))
  end
  return true
end

local function merge_runtime_refutations(refs)
  local out = { interests = {}, checks = {} }
  local seen = {}
  for i = 1, #(refs or {}) do
    local ref = refs[i]
    for j = 1, #((ref and ref.interests) or {}) do
      local x = ref.interests[j]
      local id = x.id or tostring(x)
      if not seen[id] then seen[id] = true; out.interests[#out.interests + 1] = x end
    end
  end
  return out
end

function Runtime:_pending_status(refs, unknown)
  local ref = merge_runtime_refutations(refs)
  local waits = Interest.summarise(Interest.merge(ref.interests))
  if unknown then return { tag = 'pending', kind = 'budget', interests_incomplete = true, waits = waits, interests = waits } end
  if #waits > 0 then return { tag = 'pending', kind = 'wakeup', waits = waits, interests = waits } end
  return { tag = 'quiescent', reason = self.quiet_deadlock and 'quiet-deadlock' or 'retry without actionable interest' }
end

function Runtime:_start_one()
  local head, tail = self._ready_head, self._ready_tail
  if head > tail then return nil end

  local fiber = self._ready_fibers[head]
  self._ready_fibers[head] = nil
  head = head + 1
  if head > tail then
    -- Reset the consumed queue so indices and the backing table do not grow
    -- with the lifetime of a long-running runtime.
    self._ready_fibers = {}
    self._ready_head = 1
    self._ready_tail = 0
  else
    self._ready_head = head
  end

  self:_resume_fiber(fiber)
  return fiber
end

function Runtime:_step_impl(opts)
  opts = opts or {}
  local search_limit
  if opts.max_work then
    self._bounded_credit = (self._bounded_credit or 0) + math.max(1, opts.max_work)
    search_limit = self._bounded_credit
  else
    self._bounded_credit = 0
  end
  local fiber = self:_start_one()
  if search_limit and search_limit <= 1 then
    return { tag = 'pending', kind = fiber and 'started' or 'budget', interests_incomplete = true }
  end
  if fiber then
    local request = self.pending[#self.pending]
    if request and request.fiber == fiber then
      local candidate, ref, unknown = self:_find_candidate(request.id, search_limit)
      if candidate and not candidate.negative_guard then
        local ok = self:_commit(candidate)
        if ok then self._bounded_credit = 0; return { tag = 'found', kind = 'commit', value = true } end
      end
      return self:_pending_status({ref}, unknown)
    end
    return { tag = 'pending', kind = 'started' }
  end

  if #self.pending == 0 then
    if self._live_fibers > 0 then return { tag = 'pending', kind = 'no-ready-work' } end
    return { tag = 'idle', value = true }
  end

  -- Bounded stepping must not pin itself to the oldest blocked request. Try
  -- each pending focus in round-robin order until one commit is found. This is
  -- the single-step counterpart of Runtime:run's all-focus pass and allows
  -- background pumps and policy monitors to progress behind a blocked root.
  local count = #self.pending
  local start = ((self._step_cursor or 0) % count) + 1
  local refs, any_unknown = {}, false
  for offset = 0, count - 1 do
    local idx = ((start + offset - 1) % count) + 1
    local request = self.pending[idx]
    local focus = request and request.id
    if focus and self.pending_by_id[focus] then
      local candidate, ref, unknown = self:_find_candidate(focus, search_limit)
      refs[#refs + 1] = ref
      any_unknown = any_unknown or unknown == true
      if candidate then
        local ok = self:_commit(candidate)
        if not ok and self.pending_by_id[focus] then
          self.stats.refreshes = self.stats.refreshes + 1
          if self.instrumentation then self.instrumentation:inc('refreshes') end
          candidate, ref, unknown = self:_find_candidate(focus, search_limit)
          refs[#refs + 1] = ref
          any_unknown = any_unknown or unknown == true
          if candidate then ok = self:_commit(candidate) end
        end
        if ok then
          self._step_cursor = idx
          self._bounded_credit = 0; return { tag = 'found', kind = 'commit', value = true }
        end
      end
    end
  end
  self._step_cursor = start
  return self:_pending_status(refs, any_unknown)
end

function Runtime:_run_impl(opts)
  opts = opts or {}
  if opts.max_work then return self:step(opts) end
  local committed = false
  local last_refs, last_unknown = {}, false

  -- Start fibres in scheduler order. Closed positive worlds may commit before
  -- later fibres are entered; absence-certified fallbacks wait until all
  -- currently runnable fibres have exposed their attempts.
  while true do
    local fiber = self:_start_one()
    if not fiber then break end
    local request = self.pending[#self.pending]
    if request and request.fiber == fiber then
      local candidate = self:_find_candidate(request.id)
      -- During fibre entry, commit only a closed world belonging solely to the
      -- newly entered request. A later-started background fibre must not recruit
      -- an older pending participant through that participant's non-preferred
      -- choice branch before the older request has had its own scheduling turn.
      -- Multi-participant worlds are considered by the ordinary all-focus pass
      -- once all currently runnable fibres have exposed their attempts.
      if candidate and not candidate.negative_guard
          and #candidate.participants == 1
          and candidate.participants[1] == request.id then
        local ok = self:_commit(candidate)
        if ok then committed = true end
      end
    end
  end

  while #self.pending > 0 do
    local ids = {}
    for i = 1, #self.pending do ids[i] = self.pending[i].id end
    local plans, refs, unknowns = {}, {}, {}
    for i = 1, #ids do
      if self.pending_by_id[ids[i]] then
        plans[i], refs[i], unknowns[i] = self:_find_candidate(ids[i])
      end
    end

    local progressed = false
    last_refs, last_unknown = refs, false
    for i = 1, #unknowns do if unknowns[i] then last_unknown = true end end
    for i = 1, #ids do
      local focus = ids[i]
      if self.pending_by_id[focus] then
        local candidate = plans[i]
        if candidate then
          local ok = self:_commit(candidate)
          if not ok and self.pending_by_id[focus] then
            self.stats.refreshes = self.stats.refreshes + 1
            if self.instrumentation then self.instrumentation:inc('refreshes') end
            candidate, refs[i], unknowns[i] = self:_find_candidate(focus)
            if candidate then ok = self:_commit(candidate) end
          end
          if ok then committed, progressed = true, true end
        end
      end
    end

    while self:_start_one() do progressed = true end
    if not progressed then break end
  end

  if committed then return { tag = 'found', value = true } end
  if #self.pending == 0 then return { tag = 'idle', value = true } end
  return self:_pending_status(last_refs, last_unknown)
end


local function driver_call(self, action, fn, ...)
  self:_check_not_failed(2)
  self:_require_driver_call(action, 2)
  local old = self:_set_phase('driver')
  self._driver_depth = (self._driver_depth or 0) + 1
  local result = pack_(pcall(fn, self, ...))
  self._driver_depth = math.max((self._driver_depth or 1) - 1, 0)
  self:_restore_phase(old)
  if not result[1] then
    local err = result[2]
    -- Structured scope reports are already the public failure object. Preserve
    -- them across the driver boundary rather than obscuring them inside a
    -- generic RuntimeError.
    if type(err) == 'table' and (err._fibers_error or err._fibers_scope_report) then error(err, 0) end
    return self:_fail('runtime_error', err, { phase = action, level = 0 })
  end
  return unpack_(result, 2, result.n)
end

function Runtime:step(opts)
  return driver_call(self, 'step', Runtime._step_impl, opts)
end

function Runtime:run(opts)
  return driver_call(self, 'run', Runtime._run_impl, opts)
end

function Runtime:_pump()
  self:_check_not_failed(2)
  self:_require_driver_call('pump', 2)
  local old = self:_set_phase('driver')
  self._driver_depth = (self._driver_depth or 0) + 1
  while self:_start_one() do end
  self._driver_depth = self._driver_depth - 1
  self:_restore_phase(old)
  return true
end

return Runtime
