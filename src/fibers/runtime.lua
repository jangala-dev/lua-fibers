-- Open-world fibre scheduler and commit driver.

local Op = require('fibers.op')
local Ledger = require('fibers.internal.kernel.ledger')
local Interest = require('fibers.external.interest')
local ExternalFeed = require('fibers.external.feed')
local Protected = require('fibers.internal.protected')
local Machine = require('fibers.internal.kernel.machine')
local IR = require('fibers.internal.kernel.ir')
local Instrumentation = require('fibers.internal.kernel.instrumentation')
local Dependencies = require('fibers.internal.kernel.dependencies')
local DependencyIndex = Dependencies.Index
local Certificate = require('fibers.internal.kernel.certificate')
local Path = require('fibers.internal.kernel.path')

local Runtime = {}
local EMPTY_ARRAY = {}
local native_table_clear = table.clear
local function clear_table(values)
  if native_table_clear then
    native_table_clear(values)
  else
    for key in pairs(values) do
      values[key] = nil
    end
  end
  return values
end

-- A fibre can have at most one outstanding perform.  Pending-request state is
-- therefore stored directly on the fibre rather than allocated as a separate
-- hand-off/request/response object.
local PERFORM_YIELD = {}

local function clear_pending_fields(fiber)
  fiber.id = nil
  fiber.op = nil
  fiber.symmetry_key = nil
  fiber.interrupt = nil
  fiber.metadata = nil
  fiber._dependency_plan = nil
  fiber.activation_root = nil
  if fiber.memo then
    clear_table(fiber.memo)
  else
    fiber.memo = {}
  end
  return fiber
end

local function reuse_table(runtime, field)
  local value = runtime[field]
  if not value then
    value = {}
    runtime[field] = value
  else
    clear_table(value)
  end
  return value
end

local function select_machine(opts)
  local requested = opts.machine
  if requested == nil and os and os.getenv then
    requested = os.getenv('FIBERS_MACHINE')
  end
  if requested == 'reference' then
    local ok, reference = pcall(require, 'fibers.internal.reference_machine')
    if not ok then
      error('the reference solver is a repository-only development component: ' .. tostring(reference), 3)
    end
    return reference, 'reference'
  end
  if requested ~= nil and requested ~= 'ledger' then
    error('unknown fibers machine: ' .. tostring(requested), 3)
  end
  return Machine, 'ledger'
end
Runtime.__index = Runtime
local CURRENT_RUNTIME = nil
local CURRENT_SCOPE = nil
function Runtime.current()
  return CURRENT_RUNTIME
end
function Runtime.current_scope()
  return CURRENT_SCOPE
end

local unpack_ = table.unpack or unpack
local pack_ = Op._pack
local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function merge_effects(effects)
  local order, by_key = {}, {}
  for i = 1, #effects do
    local effect = effects[i]
    local kind = effect.kind
    local key = tostring(kind._fibers_kind_id or kind.name) .. '\0' .. tostring(kind.key(effect.payload))
    local old = by_key[key]
    if old then
      local payload, err = kind.merge(old.payload, effect.payload)
      if not payload then
        return nil, err
      end
      old.payload = payload
    else
      local copy = { _fibers_effect = true, kind = kind, payload = effect.payload }
      by_key[key] = copy
      order[#order + 1] = key
    end
  end
  local out = {}
  for i = 1, #order do
    out[i] = by_key[order[i]]
  end
  return out
end

local Cancellation = {}
Cancellation.__index = Cancellation
Cancellation.__tostring = function(e)
  return e.message or 'fiber cancelled'
end
function Runtime.cancelled(reason, token)
  return setmetatable({
    _fibers_cancelled = true,
    reason = reason,
    token = token,
    message = reason and tostring(reason) or 'fiber cancelled',
  }, Cancellation)
end
function Runtime.is_cancelled(e)
  return type(e) == 'table' and e._fibers_cancelled == true
end

local RuntimeError = {}
RuntimeError.__index = RuntimeError
RuntimeError.__tostring = function(e)
  return e.message or tostring(e.cause)
end

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

function Runtime:failed()
  return self._failed
end
function Runtime:_check_not_failed(level)
  if self._failed then
    error(self._failed, level or 0)
  end
end

function Runtime:_is_current_fiber()
  local f = self._current_fiber
  if not f then
    return false
  end
  -- Yieldable protected calls may execute user code in a child coroutine.
  -- Resolve that child back to the owning runtime fibre before enforcing the
  -- perform/driver phase boundary.
  local running = Protected.running(coroutine.running())
  return running == f.co
end

function Runtime:_require_perform_allowed(level)
  if self:_is_current_fiber() and self._phase == 'fiber' then
    return true
  end
  return self:_fail('phase_error', 'perform may only be called by the currently resumed runtime fibre', {
    action = 'perform',
    phase = self._phase,
    level = level or 0,
  })
end

function Runtime:_require_spawn_allowed(level)
  if self._phase == 'external' or self._phase == 'fiber' then
    return true
  end
  return self:_fail('phase_error', 'spawn may not be called from runtime internals', {
    action = 'spawn',
    phase = self._phase,
    level = level or 0,
  })
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fiber() and self._phase == 'external' then
    return true
  end
  return self:_fail('phase_error', tostring(action) .. ' may only be called by external driver code', {
    action = action,
    phase = self._phase,
    level = level or 0,
  })
end

local function finish_phase_call(self, old_phase, name, kind, fatal, committed, ok, ...)
  self._phase = old_phase
  if ok then
    return ...
  end
  local err = ...
  if type(err) == 'table' and err._fibers_error and not fatal then
    error(err, 0)
  end
  if fatal then
    return self:_fatal(kind or 'effect_error', err, { phase = name, committed = committed, level = 0 })
  end
  return self:_fail(kind or 'callback_error', err, { phase = name, level = 0 })
end

function Runtime:_set_phase(name)
  local old = self._phase
  self._phase = name
  return old
end
function Runtime:_restore_phase(old)
  self._phase = old
end
function Runtime:_call_in_phase(name, kind, fn, ...)
  local old = self:_set_phase(name)
  return finish_phase_call(self, old, name, kind, false, nil, pcall(fn, ...))
end
function Runtime:_call_fatal_in_phase(name, kind, committed, fn, ...)
  local old = self:_set_phase(name)
  return finish_phase_call(self, old, name, kind, true, committed, pcall(fn, ...))
end

local function optional_positive_integer(value, name)
  if value == nil then
    return nil
  end
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    error(name .. ' must be a positive integer', 3)
  end
  value = math.floor(value)
  if value < 1 then
    error(name .. ' must be a positive integer', 3)
  end
  return value
end

function Runtime.new(opts)
  opts = opts or {}
  local machine, machine_name = select_machine(opts)
  local search_total_limit = optional_positive_integer(opts.search_total_limit, 'search_total_limit')
  local search_trail_limit = optional_positive_integer(opts.search_trail_limit, 'search_trail_limit')
  local search_depth_limit = optional_positive_integer(opts.search_depth_limit, 'search_depth_limit')
  local search_limits
  if search_total_limit or search_trail_limit or search_depth_limit then
    search_limits = { total = search_total_limit, trail = search_trail_limit, depth = search_depth_limit }
  end
  local instrumentation = nil
  if opts.instrumentation then
    instrumentation = Instrumentation.new(opts.instrumentation)
  end
  return setmetatable({
    opts = opts,
    host = opts.host or {},
    _phase = 'external',
    _driver_depth = 0,
    _failed = nil,
    quiet_deadlock = opts.quiet_deadlock == true,
    search_limit = opts.search_limit or 1000000,
    search_total_limit = search_total_limit,
    search_trail_limit = search_trail_limit,
    search_depth_limit = search_depth_limit,
    search_limits = search_limits,
    choice_seed = opts.choice_seed or 1,
    _ready_fibers = {},
    _ready_head = 1,
    _ready_tail = 0,
    _live_fibers = 0,
    pending = {},
    pending_by_id = {},
    dependency_index = opts.dependency_index == false and nil or DependencyIndex.new(),
    dependency_index_threshold = math.max(1, math.floor(opts.dependency_index_threshold or 8)),
    component_search = opts.component_search ~= false,
    normalise_search = opts.normalise_search ~= false,
    branch_policy = opts.branch_policy or 'constrained',
    certified_symmetry = opts.certified_symmetry ~= false,
    plan_reuse = opts.plan_reuse ~= false,
    resumable_search = opts.resumable_search ~= false,
    plan_reuse_threshold = math.max(1, math.floor(opts.plan_reuse_threshold or 16)),
    _search_sessions = {},
    _search_session_size = 0,
    _search_session_pool = {},
    _component_context_scratch = {},
    _driver_ids = {},
    _driver_refs = {},
    _driver_fallback_candidates = {},
    _driver_fallback_focuses = {},
    _driver_fallback_indices = {},
    search_session_pool = opts.search_session_pool ~= false,
    search_session_pool_limit = math.max(0, math.floor(opts.search_session_pool_limit or 64)),
    _frontier_growing = false,
    verify_dependencies = opts.verify_dependencies == true,
    next_fiber = 0,
    next_request = 0,
    pending_generation = 0,
    epoch = 0,
    external_generation = 0,
    _last_search_steps = 0,
    _external_feeds = setmetatable({}, { __mode = 'kv' }),
    _finalizers = {},
    _finalized = false,
    machine = machine,
    machine_name = machine_name,
    activation = machine.path or Path,
    instrumentation = instrumentation,
    stats = {
      plans = 0,
      search_sessions = 0,
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

function Runtime:_add_finalizer(fn)
  if type(fn) ~= 'function' then
    error('runtime finalizer must be a function', 2)
  end
  if self._finalized then
    error('runtime is already finalised', 2)
  end
  self._finalizers[#self._finalizers + 1] = fn
  return fn
end

function Runtime:_finalize()
  if self._finalized then
    return true
  end
  self._finalized = true
  local first_err
  for i = #self._finalizers, 1, -1 do
    local called, ok, err = pcall(self._finalizers[i])
    if first_err == nil then
      if not called then
        first_err = ok
      elseif ok == nil or ok == false then
        first_err = err or 'runtime finalizer failed'
      end
    end
    self._finalizers[i] = nil
  end
  if first_err ~= nil then
    error(first_err, 0)
  end
  return true
end

function Runtime:instrumentation_snapshot()
  if not self.instrumentation then
    return nil
  end
  return self.instrumentation:snapshot()
end

function Runtime:reset_instrumentation()
  if self.instrumentation then
    self.instrumentation:reset()
  end
  return self
end

function Runtime:_acquire_search_session()
  if not self.search_session_pool then
    return nil
  end
  local pool = self._search_session_pool
  local n = #pool
  if n == 0 then
    return nil
  end
  local session = pool[n]
  pool[n] = nil
  session.pooled = false
  self.stats.search_session_reuses = (self.stats.search_session_reuses or 0) + 1
  if self.instrumentation then
    self.instrumentation:inc('search_session_reuses')
  end
  return session
end

function Runtime:_release_search_session(session)
  if not self.search_session_pool or self.search_session_pool_limit == 0 or session.pooled then
    return
  end
  local pool = self._search_session_pool
  if #pool >= self.search_session_pool_limit then
    return
  end
  session.pooled = true
  pool[#pool + 1] = session
  if self.instrumentation then
    self.instrumentation:inc('search_session_pool_releases')
    self.instrumentation:max('search_session_pool_size', #pool)
  end
end

function Runtime:_resume_request(request, outcome, cancelled)
  local fiber = request
  local packed, wrap = outcome and outcome.pack or nil, outcome and outcome.wrap or nil
  clear_pending_fields(fiber)
  self:_resume_fiber(fiber, cancelled, packed, wrap)
end

function Runtime:push_scope(scope)
  local fiber = self._current_fiber
  if not fiber then
    error('Runtime:push_scope requires current fibre', 2)
  end
  fiber.scope_stack = fiber.scope_stack or {}
  fiber.scope_stack[#fiber.scope_stack + 1] = scope
  fiber.scope = scope
  CURRENT_SCOPE = scope
  return { fiber = fiber, depth = #fiber.scope_stack, scope = scope }
end

function Runtime:pop_scope(token)
  local fiber = self._current_fiber
  if not token or token.fiber ~= fiber then
    error('Runtime:pop_scope token mismatch', 2)
  end
  local stack = fiber.scope_stack or {}
  if #stack ~= token.depth or stack[#stack] ~= token.scope then
    error('Runtime:pop_scope stack mismatch', 2)
  end
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
  if not ok then
    error(packed[2], 0)
  end
  return unpack_(packed, 2, packed.n)
end

function Runtime:now()
  local now = self.host and self.host.now
  if type(now) == 'function' then
    return now(self)
  end
  return 0
end

function Runtime:external_feed(resource)
  return ExternalFeed.for_resource(self, resource)
end

function Runtime:deliver(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('external delivery', 2)
  if not ExternalFeed.is_feed(feed) then
    error('Runtime:deliver expects an ExternalFeed', 2)
  end
  if feed.runtime ~= self then
    error('external feed belongs to another runtime', 2)
  end
  feed:_deliver(...)
  self.epoch = self.epoch + 1
  self.external_generation = self.external_generation + 1
  return feed.resource
end

function Runtime:clear_external(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('clear external resource', 2)
  if not ExternalFeed.is_feed(feed) then
    error('Runtime:clear_external expects an ExternalFeed', 2)
  end
  if feed.runtime ~= self then
    error('external feed belongs to another runtime', 2)
  end
  feed:_clear(...)
  self.epoch = self.epoch + 1
  self.external_generation = self.external_generation + 1
  return feed.resource
end

function Runtime:signal(name)
  local resource = require('fibers.external.signal').new(name)
  return resource, self:external_feed(resource)
end

function Runtime:events(name)
  local resource = require('fibers.external.event_queue').new(name)
  return resource, self:external_feed(resource)
end

function Runtime:readiness(key, name)
  local resource = require('fibers.external.readiness').new(key, nil, name)
  return resource, self:external_feed(resource)
end

local function spawn_unchecked(self, fn, name, scope)
  if type(fn) ~= 'function' then
    error('spawn expects a function', 3)
  end
  self.next_fiber = self.next_fiber + 1
  local fiber = {
    fiber_id = self.next_fiber,
    name = name or ('fiber-' .. tostring(self.next_fiber)),
    co = coroutine.create(fn),
    started = false,
    done = false,
    scope = scope,
    scope_stack = scope and { scope } or {},
    memo = {},
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
    if req.interrupt == token then
      ids[#ids + 1] = req.id
      requests[#requests + 1] = req
    end
  end
  if #ids > 0 then
    self:_remove_pending(ids)
  end
  for i = 1, #requests do
    self:_resume_request(requests[i], nil, Runtime.cancelled(reason, token))
  end
  return true
end

function Runtime:_perform_current(op, interrupt, masked)
  if interrupt and interrupt.raised and not masked then
    error(Runtime.cancelled(interrupt.reason, interrupt), 0)
  end
  local cancelled, packed, wrap = coroutine.yield(PERFORM_YIELD, op, masked and nil or interrupt)
  if cancelled then
    error(cancelled, 0)
  end
  if wrap then
    packed = wrap(packed)
  end
  return unpack_pack(packed)
end

function Runtime:perform(op, opts)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  if not Op.is_op(op) then
    error('perform expects an Op', 2)
  end
  return self:_perform_current(op, opts and opts.interrupt, opts and opts.masked)
end

function Runtime:_index_request(request)
  if not self.dependency_index or not request or request._dependency_plan then
    return request
  end
  local metadata = request.metadata or IR.metadata(request.op)
  request.metadata = metadata
  self.dependency_index:add(request)
  return request
end

function Runtime:_index_pending_frontier()
  if not self.dependency_index then
    return
  end
  for i = 1, #self.pending do
    self:_index_request(self.pending[i])
  end
end

function Runtime:_add_pending(fiber, op, interrupt)
  self.next_request = self.next_request + 1
  local request = fiber
  clear_table(request.memo)
  request.id = self.next_request
  request.activation_root = self.activation.new_request(request.id)
  request.op = op
  request.symmetry_key = Op._symmetry_key(op)
  request.interrupt = interrupt
  self.pending[#self.pending + 1] = request
  self.pending_by_id[request.id] = request
  -- Dependency buckets are promoted only after the frontier has demonstrated
  -- a need for retention/component isolation.  Once promoted, new admissions
  -- join the existing index immediately so their bucket generations invalidate
  -- retained proofs precisely.
  if self.dependency_index and self.dependency_index.size > 0 then
    self:_index_request(request)
  end
  self.pending_generation = self.pending_generation + 1
  local instrumentation = self.instrumentation
  local metadata
  if instrumentation then
    metadata = request.metadata or IR.metadata(op)
    request.metadata = metadata
    instrumentation:inc('perform_yields')
    instrumentation:max('pending_requests', #self.pending)
    if metadata.dynamic then
      instrumentation:inc('requests_dynamic')
    else
      instrumentation:inc('requests_analysable')
    end
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
  if fiber.done then
    return
  end
  fiber.done = true
  -- A completed fibre handle remains useful for identity and diagnostics, but
  -- its coroutine and dynamic scope graph must not be retained by the runtime.
  fiber.co = nil
  fiber.scope = nil
  fiber.scope_stack = nil
  self._live_fibers = math.max(self._live_fibers - 1, 0)
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('fibres_completed')
  end
end

function Runtime:_resume_fiber(fiber, a, b, c)
  local ok, yielded, yielded_op, yielded_interrupt
  local instrumentation = self.instrumentation
  local resume_started = instrumentation and instrumentation.clock() or nil
  if instrumentation then
    instrumentation:inc('fibre_resumes')
  end
  local previous, previous_scope, previous_fiber = CURRENT_RUNTIME, CURRENT_SCOPE, self._current_fiber
  self._current_fiber = fiber
  CURRENT_RUNTIME, CURRENT_SCOPE = self, fiber.scope
  local old_phase = self:_set_phase('fiber')
  if fiber.started then
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co, a, b, c)
  else
    fiber.started = true
    ok, yielded, yielded_op, yielded_interrupt = coroutine.resume(fiber.co)
  end
  self:_restore_phase(old_phase)
  if instrumentation then
    instrumentation:inc(
      'fibre_cpu_ns',
      math.floor((instrumentation.clock() - resume_started) * 1000000000 + 0.5)
    )
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
  if yielded ~= PERFORM_YIELD or not Op.is_op(yielded_op) then
    self:_finish_fiber(fiber)
    error('runtime received an unsupported coroutine yield', 0)
  end
  self:_add_pending(fiber, yielded_op, yielded_interrupt)
end

function Runtime:_take_search_session(focus_id)
  local row = self._search_sessions[focus_id]
  if not row then
    return nil
  end
  self._search_sessions[focus_id] = nil
  self._search_session_size = math.max(0, (self._search_session_size or 1) - 1)
  return row
end

function Runtime:_clear_search_session(focus_id, reason)
  local row = self:_take_search_session(focus_id)
  if not row then
    return
  end
  if row.session then
    row.session:discard(reason or 'invalidated')
  end
  if self.instrumentation then
    self.instrumentation:inc('search_session_invalidations')
  end
end

function Runtime:_store_search_session(focus_id, kind, session, certificate)
  if not self._search_sessions[focus_id] then
    self._search_session_size = (self._search_session_size or 0) + 1
  end
  local row = {
    kind = kind,
    session = session,
    certificate = Certificate.copy(certificate),
  }
  self._search_sessions[focus_id] = row
  local instrumentation = self.instrumentation
  if instrumentation then
    if kind == 'certificate' then
      instrumentation:inc('plan_reuse_stores')
    else
      instrumentation:inc('search_session_stores')
    end
    instrumentation:max('search_sessions_retained', self._search_session_size)
  end
end

function Runtime:_remove_pending_small(count, id1, id2)
  local write, total = 1, #self.pending
  for read = 1, total do
    local request = self.pending[read]
    local selected = request.id == id1 or (count == 2 and request.id == id2)
    if selected then
      if self.dependency_index and request._dependency_plan then
        self.dependency_index:remove(request)
      end
      self.pending_by_id[request.id] = nil
      self:_clear_search_session(request.id, 'removed')
    else
      if write ~= read then
        self.pending[write] = request
      end
      write = write + 1
    end
  end
  for i = write, total do
    self.pending[i] = nil
  end
  self.pending_generation = self.pending_generation + 1
  if self.instrumentation then
    self.instrumentation:inc('pending_removed', count)
  end
end

function Runtime:_remove_pending(ids)
  local count = #ids
  local remove
  if count > 4 then
    remove = reuse_table(self, '_remove_pending_scratch')
    for i = 1, count do
      remove[ids[i]] = true
    end
  end
  local function selected(id)
    if remove then
      return remove[id] == true
    end
    for i = 1, count do
      if ids[i] == id then
        return true
      end
    end
    return false
  end

  local write, total = 1, #self.pending
  for read = 1, total do
    local request = self.pending[read]
    if selected(request.id) then
      if self.dependency_index and request._dependency_plan then
        self.dependency_index:remove(request)
      end
      self.pending_by_id[request.id] = nil
      self:_clear_search_session(request.id, 'removed')
    else
      if write ~= read then
        self.pending[write] = request
      end
      write = write + 1
    end
  end
  for i = write, total do
    self.pending[i] = nil
  end
  self.pending_generation = self.pending_generation + 1
  local instrumentation = self.instrumentation
  if instrumentation then
    instrumentation:inc('pending_removed', count)
  end
end

function Runtime:_component_requests(focus_id)
  local focus = self.pending_by_id[focus_id]
  if not focus then
    return {}, self.instrumentation and { total = 0, size = 0 } or nil
  end

  if self.dependency_index and not focus._dependency_plan then
    local promote = self.dependency_index.size > 0
      or #self.pending >= self.dependency_index_threshold
      or self._search_session_size > 0
    -- Choice order is component-local.  Choices are uncommon enough that
    -- compiling their metadata here is preferable to globalising their order.
    local needs_choice_generation = false
    if not promote then
      local kind = focus.op and focus.op.kind
      if kind == 'choice' or kind == 'or_else' or kind == 'product' then
        local metadata = focus.metadata or IR.metadata(focus.op)
        focus.metadata = metadata
        needs_choice_generation = (metadata.node_kinds or {}).choice ~= nil
        promote = needs_choice_generation and #self.pending > 1
      end
    end
    if promote then
      self:_index_pending_frontier()
    elseif needs_choice_generation then
      focus._needs_choice_generation = true
    end
  end

  if not self.component_search or not self.dependency_index then
    if not self.instrumentation and self._search_sessions[focus_id] == nil then
      return self.pending_by_id, nil
    end
    local total, ids = #self.pending, {}
    for id in pairs(self.pending_by_id) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    return self.pending_by_id,
      {
        total = total,
        size = total,
        global = true,
        disabled = true,
        ids = ids,
        order_generation = self.pending_generation,
      }
  end

  if not focus._dependency_plan then
    -- Small, unretained frontiers use the request map directly.  A component
    -- record is allocated only when diagnostics, choice ordering or retained
    -- work actually need one; Retry capture may promote and return an indexed
    -- component later.
    if
      not self.instrumentation
      and self._search_sessions[focus_id] == nil
      and not focus._needs_choice_generation
    then
      return self.pending_by_id, nil
    end
    local component = {
      total = #self.pending,
      size = #self.pending,
      dynamic = 0,
      global = true,
      edge_visits = 0,
      direct = true,
      order_generation = self.pending_generation,
    }
    local ids = {}
    for id in pairs(self.pending_by_id) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    component.ids = ids
    return self.pending_by_id, component
  end

  local diagnostics = self.instrumentation ~= nil or self._search_sessions[focus_id] ~= nil
  local requests, component = self.dependency_index:component(focus_id, self.pending_by_id, diagnostics)
  return requests, component
end

local function better_supplier(id, score, best)
  return not best or score > best.score or score == best.score and id < best.id
end

function Runtime:_has_supplier(intents, entered, excluded, requests, required_certainty)
  requests = requests or self.pending_by_id
  if self.dependency_index and self.dependency_index.size == #self.pending then
    local found = false
    self.dependency_index:each_supplier(intents, requests, entered, excluded, function()
      found = true
      return false
    end, required_certainty)
    return found
  end
  for id, request in pairs(requests) do
    if not (entered and entered[id]) and not (excluded and excluded[id]) then
      local metadata = request.metadata or IR.metadata(request.op)
      request.metadata = metadata
      if required_certainty == nil then
        if IR.metadata_may_supply_any(metadata, intents) then
          return true
        end
      else
        local score, certainty = IR.supply_score(metadata, intents)
        if score > 0 and certainty == required_certainty then
          return true
        end
      end
    end
  end
  return false
end

function Runtime:_supplier_request(intents, entered, excluded, requests)
  requests = requests or self.pending_by_id
  local best, candidate_count = nil, 0
  local function consider(id, score, _certainty, reason, request)
    candidate_count = candidate_count + 1
    local symmetry = self.certified_symmetry and request.symmetry_key or nil
    if better_supplier(id, score, best) then
      best = { id = id, score = score, reason = reason, symmetry_key = symmetry }
      if symmetry ~= nil then
        best.equivalent_ids = { id }
      end
    elseif
      best
      and symmetry ~= nil
      and best.symmetry_key ~= nil
      and type(symmetry) == type(best.symmetry_key)
      and symmetry == best.symmetry_key
      and score == best.score
      and reason == best.reason
    then
      best.equivalent_ids[#best.equivalent_ids + 1] = id
    end
  end

  if self.dependency_index and self.dependency_index.size == #self.pending then
    self.dependency_index:each_supplier(intents, requests, entered, excluded, consider)
  else
    for id, request in pairs(requests) do
      if not (entered and entered[id]) and not (excluded and excluded[id]) then
        local metadata = request.metadata or IR.metadata(request.op)
        request.metadata = metadata
        local score, certainty, reason = IR.supply_score(metadata, intents)
        if score > 0 then
          consider(id, score, certainty, reason, request)
        end
      end
    end
  end
  if best and best.equivalent_ids and #best.equivalent_ids > 1 and self.instrumentation then
    self.instrumentation:inc('symmetry_supplier_pruned', #best.equivalent_ids - 1)
  end
  if best then
    best.symmetry_key = nil
  end
  return best, candidate_count
end

function Runtime:_search_session_certificate(requests, component, focus_id, session, certificate)
  if self._frontier_growing then
    return nil, 'frontier-growing'
  end
  if
    self.dependency_index
    and focus_id
    and self.pending_by_id[focus_id]
    and not self.pending_by_id[focus_id]._dependency_plan
  then
    self:_index_pending_frontier()
    local indexed_requests, indexed_component = self:_component_requests(focus_id)
    requests = indexed_requests
    if component and indexed_component and component ~= indexed_component then
      for key in pairs(component) do
        component[key] = nil
      end
      for key, value in pairs(indexed_component) do
        component[key] = value
      end
    else
      component = indexed_component or component
    end
  end
  local certificate, reason =
    Certificate.capture(self, requests, component, certificate or (session and session.result_certificate))
  if certificate and self.instrumentation then
    self.instrumentation:inc('certificates')
  end
  return certificate, reason, component
end

local function component_request_ids(requests, component)
  if component and component.ids then
    return component.ids
  end
  local ids = {}
  for id in pairs(requests or {}) do
    ids[#ids + 1] = id
  end
  return ids
end

function Runtime:_component_context(focus_id)
  local requests, component = self:_component_requests(focus_id)
  local context = self._component_context_scratch
  context.focus_id = focus_id
  context.requests = requests
  context.component = component
  return context
end

function Runtime:_store_lightweight_certificate(focus_id, requests, component, certificate)
  local instrumentation = self.instrumentation
  if
    self._frontier_growing
    or not self.plan_reuse
    or (component and component.dynamic and component.dynamic > 0)
    or #self.pending < self.plan_reuse_threshold
  then
    if instrumentation and component and component.dynamic and component.dynamic > 0 then
      instrumentation:inc('plan_reuse_ineligible')
      instrumentation:inc('plan_reuse_ineligible_dynamic')
    end
    return false, component
  end
  local ids = component_request_ids(requests, component)
  for i = 1, #ids do
    local request = requests[ids[i]]
    if request then
      local metadata = request.metadata or IR.metadata(request.op)
      request.metadata = metadata
      if metadata.dynamic then
        if instrumentation then
          instrumentation:inc('plan_reuse_ineligible')
          instrumentation:inc('plan_reuse_ineligible_dynamic')
        end
        return false, component
      end
    end
  end
  local certificate, reason, retained_component =
    self:_search_session_certificate(requests, component, focus_id, nil, certificate)
  component = retained_component or component
  if not certificate then
    if instrumentation then
      instrumentation:inc('plan_reuse_ineligible')
      instrumentation:inc('plan_reuse_ineligible_' .. tostring(reason or 'unknown'))
    end
    return false, component
  end
  self:_store_search_session(focus_id, 'certificate', nil, certificate)
  return true, component
end

function Runtime:_find_candidate_impl(focus_id, search_limit, context)
  if not self.pending_by_id[focus_id] then
    return nil
  end
  local requests, component
  if context and context.focus_id == focus_id then
    requests, component = context.requests, context.component
    if self.instrumentation then
      self.instrumentation:inc('component_context_reuses')
    end
  else
    requests, component = self:_component_requests(focus_id)
  end
  local instrumentation = self.instrumentation

  local retained = self.resumable_search and self._search_sessions[focus_id] or nil
  local hit, certificate, unknown, session
  if retained then
    local valid, invalid_reason = Certificate.valid(retained.certificate, self)
    if valid then
      if retained.kind == 'certificate' then
        if instrumentation then
          instrumentation:inc('plan_reuse_hits')
          instrumentation:inc('plan_reuse_refutation_hits')
        end
        return nil, Certificate.copy(retained.certificate), false
      end
      if instrumentation then
        instrumentation:inc('search_session_resumes')
      end
      hit, certificate, unknown = retained.session:advance(search_limit or self.search_limit)
      session = retained.session
      if unknown and session.hard_limit then
        local unknown_reason = session.unknown_reason
        self._last_search_unknown_reason = unknown_reason or 'search_quantum'
        self:_take_search_session(focus_id)
        session:discard(unknown_reason or 'hard-search-limit')
      elseif unknown then
        self._last_search_unknown_reason = session.unknown_reason or 'search_quantum'
      else
        self:_take_search_session(focus_id)
        if hit == nil then
          session:discard('completed-retry')
          self:_store_lightweight_certificate(focus_id, requests, component, certificate)
        end
      end
      return hit, certificate, unknown
    end
    if instrumentation then
      instrumentation:inc('search_session_invalidation_' .. tostring(invalid_reason or 'unknown'))
      if retained.kind == 'certificate' then
        instrumentation:inc('plan_reuse_invalidations')
      end
    end
    self:_clear_search_session(focus_id, 'invalidated')
  end

  hit, certificate, unknown, session = self.machine.search(self, requests, focus_id, search_limit, component)
  if unknown and session then
    local unknown_reason = session.unknown_reason
    self._last_search_unknown_reason = unknown_reason or 'search_quantum'
    if session.hard_limit then
      session:discard(unknown_reason or 'hard-search-limit')
    elseif not self.resumable_search then
      session:discard('unretained')
    else
      local session_certificate, _, retained_component =
        self:_search_session_certificate(requests, component, focus_id, session)
      component = retained_component or component
      if session_certificate then
        self:_store_search_session(focus_id, 'active', session, session_certificate)
      else
        session:discard('unretained')
      end
    end
  elseif hit == nil then
    if session then
      session:discard('completed-retry')
    end
    self:_store_lightweight_certificate(focus_id, requests, component, certificate)
  end
  return hit, certificate, unknown
end

function Runtime:_find_candidate(focus_id, search_limit, context)
  return self:_call_in_phase('search', 'search_error', function()
    return self:_find_candidate_impl(focus_id, search_limit, context)
  end)
end

local function hit_participant_count(hit)
  if hit._fibers_session_hit then
    return hit.participant_count or 0
  end
  return #(hit.participants or {})
end

local function hit_participant_id(hit, index)
  if not hit._fibers_session_hit then
    return hit.participants[index]
  end
  if hit.participants then
    return hit.participants[index]
  end
  if index == 1 then
    return hit.participant_1
  end
  if index == 2 then
    return hit.participant_2
  end
  return nil
end

function Runtime:_validate_hit(hit)
  local participant_count = hit_participant_count(hit)
  for i = 1, participant_count do
    if not self.pending_by_id[hit_participant_id(hit, i)] then
      return false, 'participant-changed'
    end
  end
  local valid, validity_err = Ledger.validate(hit.observations)
  if not valid then
    return false, validity_err
  end
  if hit.negative_guard then
    if self.epoch ~= hit.epoch then
      return false, 'stale-negative-epoch'
    end
    if self.pending_generation ~= hit.pending_generation then
      return false, 'stale-negative-frontier'
    end
    for i = 1, #(hit.negative_checks or {}) do
      local check = hit.negative_checks[i]
      if check and type(check.validate) == 'function' and not check.validate(self, check) then
        return false, 'stale-negative-check'
      end
    end
  end
  return true
end

function Runtime:_prepare_hit_effects(hit)
  local source = hit.effects
  if not source or #source == 0 then
    return EMPTY_ARRAY
  end
  local effects, merge_err = merge_effects(source)
  if not effects then
    return nil, merge_err
  end
  local prepared = {}
  for i = 1, #effects do
    local effect = effects[i]
    local p, err =
      self:_call_in_phase('effect_prepare', 'effect_error', effect.kind.prepare, self, effect.payload)
    if not p then
      return nil, err
    end
    prepared[#prepared + 1] = p
  end
  return prepared
end

function Runtime:_commit_hit(hit)
  local instrumentation = self.instrumentation
  local commit_started = instrumentation and instrumentation.clock() or nil
  local valid, validation_reason = self:_validate_hit(hit)
  if not valid then
    self.stats.validation_failures = self.stats.validation_failures + 1
    if instrumentation then
      instrumentation:inc('validation_failures')
      instrumentation:inc('validation_failure_' .. tostring(validation_reason or 'unknown'))
      instrumentation:inc(
        'commit_cpu_ns',
        math.floor((instrumentation.clock() - commit_started) * 1000000000 + 0.5)
      )
    end
    if hit._fibers_session_hit then
      hit:discard('stale-hit')
    end
    return false, 'stale'
  end

  local prepared = hit.prepared_effects
  if not prepared then
    local err
    prepared, err = self:_prepare_hit_effects(hit)
    if not prepared then
      return false, err or 'effect-prepare-refused'
    end
  end

  local participant_count = hit_participant_count(hit)
  local id1, id2 = hit_participant_id(hit, 1), hit_participant_id(hit, 2)
  local request1, request2, outcome1, outcome2
  local requests, outcomes
  if participant_count <= 2 then
    request1 = id1 and self.pending_by_id[id1] or nil
    request2 = id2 and self.pending_by_id[id2] or nil
    if hit._fibers_session_hit then
      outcome1 = id1 and hit:outcome_for(id1) or nil
      outcome2 = id2 and hit:outcome_for(id2) or nil
    else
      outcome1 = id1 and hit.outcomes[id1] or nil
      outcome2 = id2 and hit.outcomes[id2] or nil
    end
  else
    if hit._fibers_session_hit then
      requests = hit:reuse_array('_arena_commit_requests')
      outcomes = hit:reuse_array('_arena_commit_outcomes')
    else
      requests, outcomes = {}, {}
    end
    for i = 1, participant_count do
      local id = hit_participant_id(hit, i)
      requests[i] = self.pending_by_id[id]
      outcomes[i] = hit._fibers_session_hit and hit:outcome_for(id) or hit.outcomes[id]
    end
  end

  Ledger.commit(hit.writes)
  self.epoch = self.epoch + 1
  self.stats.commits = self.stats.commits + 1
  if hit.negative_guard then
    self.stats.fallback_commits = self.stats.fallback_commits + 1
  end
  if instrumentation then
    instrumentation:inc('commits')
    instrumentation:inc('commit_participants', participant_count)
    local write_count = 0
    for _ in pairs(hit.writes or {}) do
      write_count = write_count + 1
    end
    instrumentation:inc('commit_writes', write_count)
    instrumentation:inc('commit_effects', #prepared)
    instrumentation:observe('participants_per_commit', participant_count)
    instrumentation:observe('writes_per_commit', write_count)
  end

  if participant_count <= 2 then
    self:_remove_pending_small(participant_count, id1, id2)
  else
    self:_remove_pending(hit.participants)
  end

  for i = 1, #prepared do
    local p = prepared[i]
    self:_call_fatal_in_phase('effect_discharge', 'effect_error', true, p.discharge, self, p, nil)
  end

  if participant_count <= 2 then
    if request1 then
      self:_resume_request(request1, outcome1)
    end
    if request2 then
      self:_resume_request(request2, outcome2)
    end
  else
    for i = 1, #requests do
      self:_resume_request(requests[i], outcomes[i])
    end
  end
  if hit._fibers_session_hit then
    hit:discard('committed')
  end
  if instrumentation then
    instrumentation:inc(
      'commit_cpu_ns',
      math.floor((instrumentation.clock() - commit_started) * 1000000000 + 0.5)
    )
  end
  return true
end

local function merge_runtime_certificates(refs)
  return Certificate.merge_all(refs)
end

function Runtime:_pending_status(refs, unknown)
  local certificate = merge_runtime_certificates(refs)
  local waits = Interest.summarise(Interest.merge(Certificate.values(certificate, 'interest')))
  if unknown then
    return {
      tag = 'pending',
      kind = 'budget',
      reason = self._last_search_unknown_reason or 'search_quantum',
      interests_incomplete = true,
      waits = waits,
      interests = waits,
    }
  end
  if #waits > 0 then
    return { tag = 'pending', kind = 'wakeup', waits = waits, interests = waits }
  end
  return {
    tag = 'quiescent',
    reason = self.quiet_deadlock and 'quiet-deadlock' or 'retry without actionable interest',
  }
end

function Runtime:_start_one()
  local head, tail = self._ready_head, self._ready_tail
  if head > tail then
    return nil
  end

  local fiber = self._ready_fibers[head]
  self._ready_fibers[head] = nil
  head = head + 1
  if head > tail then
    -- Reset the consumed queue so indices and the backing table do not grow
    -- with the lifetime of a long-running runtime.
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
  self._last_search_unknown_reason = nil
  local search_limit
  if opts.max_work then
    local requested = math.max(1, opts.max_work)
    if self.machine_name == 'reference' or not self.resumable_search then
      self._bounded_credit = (self._bounded_credit or 0) + requested
      search_limit = self._bounded_credit
    else
      search_limit = requested
    end
  else
    self._bounded_credit = 0
  end
  local fiber = self:_start_one()
  if fiber and search_limit and search_limit <= 1 then
    return { tag = 'pending', kind = 'started', interests_incomplete = true }
  end
  if fiber then
    local request = self.pending[#self.pending]
    if request == fiber then
      self._frontier_growing = self._ready_head <= self._ready_tail
      local candidate, ref, unknown = self:_find_candidate(request.id, search_limit)
      self._frontier_growing = false
      if candidate and not candidate.negative_guard then
        local ok = self:_commit_hit(candidate)
        if ok then
          self._bounded_credit = 0
          return { tag = 'found', kind = 'commit', value = true }
        end
      end
      local refs = reuse_table(self, '_driver_refs')
      refs[1] = ref
      return self:_pending_status(refs, unknown)
    end
    return { tag = 'pending', kind = 'started' }
  end

  if #self.pending == 0 then
    if self._live_fibers > 0 then
      return { tag = 'pending', kind = 'no-ready-work' }
    end
    return { tag = 'idle', value = true }
  end

  -- Bounded stepping must not pin itself to the oldest blocked request. Try
  -- each pending focus in round-robin order until one commit is found. This is
  -- the single-step counterpart of Runtime:run's all-focus pass and allows
  -- background services and policy monitors to progress behind a blocked root.
  local count = #self.pending
  local start = ((self._step_cursor or 0) % count) + 1
  local refs = reuse_table(self, '_driver_refs')
  local any_unknown = false
  for offset = 0, count - 1 do
    local idx = ((start + offset - 1) % count) + 1
    local request = self.pending[idx]
    local focus = request and request.id
    if focus and self.pending_by_id[focus] then
      local context = self:_component_context(focus)
      local candidate, ref, unknown = self:_find_candidate(focus, search_limit, context)
      refs[#refs + 1] = ref
      any_unknown = any_unknown or unknown == true
      if candidate then
        local ok = self:_commit_hit(candidate)
        if not ok and self.pending_by_id[focus] then
          self.stats.refreshes = self.stats.refreshes + 1
          if self.instrumentation then
            self.instrumentation:inc('refreshes')
          end
          candidate, ref, unknown = self:_find_candidate(focus, search_limit)
          refs[#refs + 1] = ref
          any_unknown = any_unknown or unknown == true
          if candidate then
            ok = self:_commit_hit(candidate)
          end
        end
        if ok then
          self._step_cursor = idx
          self._bounded_credit = 0
          return { tag = 'found', kind = 'commit', value = true }
        end
      end
    end
  end
  self._step_cursor = start
  return self:_pending_status(refs, any_unknown)
end

local function discard_candidates(values, keep)
  for i = 1, #(values or {}) do
    local candidate = values[i]
    if candidate and candidate ~= keep and candidate._fibers_session_hit then
      candidate:discard('superseded')
    end
  end
end

function Runtime:_clear_driver_scratch(keep_candidate)
  discard_candidates(self._driver_fallback_candidates, keep_candidate)
  clear_table(self._driver_refs)
  clear_table(self._driver_fallback_candidates)
  clear_table(self._driver_fallback_focuses)
  clear_table(self._driver_fallback_indices)
  local context = self._component_context_scratch
  if context then
    context.focus_id, context.requests, context.component = nil, nil, nil
  end
end

function Runtime:_run_impl(opts)
  opts = opts or {}
  self._last_search_unknown_reason = nil
  if opts.max_work then
    return self:step(opts)
  end
  local committed = false
  local last_refs, last_unknown = {}, false

  -- Start fibres in scheduler order. Closed positive worlds may commit before
  -- later fibres are entered; absence-certified fallbacks wait until all
  -- currently runnable fibres have exposed their attempts.
  while true do
    local fiber = self:_start_one()
    if not fiber then
      break
    end
    local request = self.pending[#self.pending]
    if request == fiber and #self.pending == 1 then
      -- Search during admission only when this request is the complete pending
      -- frontier.  Once another request is already blocked, defer planning until
      -- all runnable fibres have exposed their attempts.  This preserves the
      -- scheduling rule for non-preferred branches and avoids constructing a
      -- multi-participant candidate which the ordinary driver pass would prove
      -- again immediately afterwards.
      self._frontier_growing = self._ready_head <= self._ready_tail
      local candidate = self:_find_candidate(request.id)
      self._frontier_growing = false
      if
        candidate
        and not candidate.negative_guard
        and hit_participant_count(candidate) == 1
        and hit_participant_id(candidate, 1) == request.id
      then
        local ok = self:_commit_hit(candidate)
        if ok then
          committed = true
        end
      end
    end
  end

  while #self.pending > 0 do
    local ids = reuse_table(self, '_driver_ids')
    for i = 1, #self.pending do
      ids[i] = self.pending[i].id
    end

    local progressed = false
    local refs = reuse_table(self, '_driver_refs')
    local fallback_candidates = reuse_table(self, '_driver_fallback_candidates')
    local fallback_focuses = reuse_table(self, '_driver_fallback_focuses')
    local fallback_indices = reuse_table(self, '_driver_fallback_indices')
    local any_unknown = false
    local start = ((self._run_cursor or 0) % #ids) + 1
    for offset = 0, #ids - 1 do
      local i = ((start + offset - 1) % #ids) + 1
      local focus = ids[i]
      if self.pending_by_id[focus] then
        local context = self:_component_context(focus)
        local component = context.component
        local candidate, ref, unknown = self:_find_candidate(focus, nil, context)
        refs[#refs + 1] = ref
        any_unknown = any_unknown or unknown == true
        if candidate and candidate.negative_guard then
          -- A certified fallback is valid only after every currently eligible
          -- focus has failed to produce positive work.  Remember the first one
          -- but continue the lazy scan; this preserves the established rule that
          -- a concurrent admission, writer or task start commits before absence.
          local n = #fallback_candidates + 1
          fallback_candidates[n], fallback_focuses[n], fallback_indices[n] = candidate, focus, i
        elseif candidate then
          local ok = self:_commit_hit(candidate)
          if not ok and self.pending_by_id[focus] then
            self.stats.refreshes = self.stats.refreshes + 1
            if self.instrumentation then
              self.instrumentation:inc('refreshes')
            end
            candidate, ref, unknown = self:_find_candidate(focus)
            refs[#refs + 1] = ref
            any_unknown = any_unknown or unknown == true
            if candidate and not candidate.negative_guard then
              ok = self:_commit_hit(candidate)
            end
          end
          if ok then
            committed, progressed = true, true
            self._run_cursor = i
            discard_candidates(fallback_candidates)
            clear_table(fallback_candidates)
            break
          end
        end
      end
    end
    if not progressed then
      for i = 1, #fallback_candidates do
        local focus, candidate = fallback_focuses[i], fallback_candidates[i]
        if self.pending_by_id[focus] then
          local ok = self:_commit_hit(candidate)
          if not ok and self.pending_by_id[focus] then
            self.stats.refreshes = self.stats.refreshes + 1
            if self.instrumentation then
              self.instrumentation:inc('refreshes')
            end
            candidate, ref, unknown = self:_find_candidate(focus)
            refs[#refs + 1] = ref
            any_unknown = any_unknown or unknown == true
            if candidate and candidate.negative_guard then
              ok = self:_commit_hit(candidate)
            end
          end
          if ok then
            committed, progressed = true, true
            self._run_cursor = fallback_indices[i]
            discard_candidates(fallback_candidates, candidate)
            clear_table(fallback_candidates)
            break
          end
        end
      end
    end
    last_refs, last_unknown = refs, any_unknown

    while self:_start_one() do
      progressed = true
    end
    if not progressed then
      break
    end
  end

  local result
  if committed then
    result = { tag = 'found', value = true }
  elseif #self.pending == 0 then
    result = { tag = 'idle', value = true }
  else
    result = self:_pending_status(last_refs, last_unknown)
  end
  self:_clear_driver_scratch()
  return result
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
    if type(err) == 'table' and (err._fibers_error or err._fibers_scope_report) then
      error(err, 0)
    end
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

function Runtime:io_audit_snapshot(opts)
  return require('fibers.internal.io_audit').snapshot(self, opts)
end

function Runtime:assert_io_quiescent(label)
  if self.host_reactor then
    self.host_reactor:assert_quiescent(label)
  end
  return require('fibers.internal.io_audit').assert_clean(self, { label = label })
end

function Runtime:_pump()
  self:_check_not_failed(2)
  self:_require_driver_call('pump', 2)
  local old = self:_set_phase('driver')
  self._driver_depth = (self._driver_depth or 0) + 1
  while self:_start_one() do
  end
  self._driver_depth = self._driver_depth - 1
  self:_restore_phase(old)
  return true
end

return Runtime
