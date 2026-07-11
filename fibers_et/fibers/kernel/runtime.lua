local Net = require('fibers.kernel.transaction_net')
local Op = require('fibers.atoms.op')
local Interest = require('fibers.kernel.interest')
local Resources = require('fibers.kernel.resources')
local Signal = require('fibers.atoms.signal')
local EventQueue = require('fibers.atoms.event_queue')
local Readiness = require('fibers.atoms.readiness')
local ExternalFeed = require('fibers.kernel.external_feed')
local Interrupt = require('fibers.internal.interrupt')
local Protected = require('fibers.kernel.protected')
local ChoiceArbiter = require('fibers.kernel.choice_arbiter')
local Runtime = {}
Runtime.__index = Runtime

local current_runtime = nil
local current_scope = nil

function Runtime.current()
  return current_runtime
end

function Runtime.current_scope()
  return current_scope
end

function Runtime._current_scope()
  return current_scope
end

local unpack_ = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local PERFORM_RESULT = {}

local Cancellation = {}
Cancellation.__index = Cancellation
Cancellation.__tostring = function(e) return e.message or 'fiber cancelled' end

function Runtime.cancelled(reason, token)
  return setmetatable({
    _fibers_cancelled = true,
    kind = 'cancelled',
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
RuntimeError.__tostring = function(e) return e.message or tostring(e.cause) end

local function pack_perform_result(vals, post)
  return { _token = PERFORM_RESULT, vals = vals, post = post }
end


local function plan_retriable(reason)
  return reason == 'stale' or reason == 'stale-cursor' or reason == 'resource-not-fresh'
end

local function plan_failure_status(reason)
  if plan_retriable(reason) then return { tag = 'pending', reason = reason or 'stale world' } end
  return { tag = 'reject_candidate', reason = reason or 'candidate rejected during commit preparation' }
end

local function score_is_zero(score)
  if not score then return true end
  for i = 1, #score do if (score[i] or 0) ~= 0 then return false end end
  return true
end

function Runtime.new(opts)
  opts = opts or {}
  local host = opts.host or {}
  local choice_opts = opts.choice or {}
  local choice_arbiter = ChoiceArbiter.new(choice_opts)
  return setmetatable({
    opts = opts,
    host = host,

    -- Live frontier state.  A live fibre is owned by exactly one of:
    --   ready queue, waiting frontier, or the currently running slot.
    -- Completed fibres are retired immediately and are not kept by the runtime.
    ready = {},
    ready_head = 1,
    ready_tail = 0,
    waiting = {},
    live_count = 0,
    _next_fibre_id = 0,

    _choice_arbiter = choice_arbiter,
    choice_policy = { mode = choice_arbiter.mode, seed = choice_arbiter.seed },

    _cursor = nil,
    _net_wait_cache = nil,
    _phase = 'external',
    _current_fibre = nil,
    _driver_depth = 0,
    _failed = nil,
    _external_feeds = setmetatable({}, { __mode = 'k' }),
  }, Runtime)
end



function Runtime:_choice_order(owner_id, op, occurrence, count)
  return self._choice_arbiter:order(owner_id, op, occurrence, count)
end

function Runtime:_commit_choice_selections(selections)
  return self._choice_arbiter:commit(selections)
end

function Runtime:now()
  local now = self.host.now or self.opts.now
  if now then return now(self) end
  return 0
end

-- External-resource delivery boundary.  External facts enter through a
-- runtime-bound capability; the resource owns the mutation protocol.
function Runtime:deliver(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('external delivery', 2)
  if not ExternalFeed.is_feed(feed) then error('Runtime:deliver expects an ExternalFeed', 2) end
  if feed.runtime ~= self then error('external feed belongs to another runtime', 2) end
  feed:_deliver(...)
  return feed.resource
end

function Runtime:clear_external(feed, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('clear external resource', 2)
  if not ExternalFeed.is_feed(feed) then error('Runtime:clear_external expects an ExternalFeed', 2) end
  if feed.runtime ~= self then error('external feed belongs to another runtime', 2) end
  feed:_clear(...)
  return feed.resource
end

function Runtime:external_feed(resource)
  return ExternalFeed.for_resource(self, resource)
end

function Runtime:signal(name)
  local resource = Signal.new(name)
  return resource, self:external_feed(resource)
end

function Runtime:events(name)
  local resource = EventQueue.new(name)
  return resource, self:external_feed(resource)
end

function Runtime:readiness(key, name)
  local resource = Readiness.new(key, nil, name)
  return resource, self:external_feed(resource)
end

function Runtime:_make_error(kind, err, fields)
  fields = fields or {}
  local message = fields.message or tostring(err)
  local out = {
    _fibers_error = true,
    kind = kind,
    phase = fields.phase or self._phase,
    fibre = fields.fibre,
    action = fields.action,
    committed = fields.committed,
    message = message,
    cause = err,
  }
  if type(err) == 'table' and err._fibers_scope_report == true then
    out.scope_report = err
    out.primary = err.primary
    out.secondaries = err.secondaries
  end
  return setmetatable(out, RuntimeError)
end

function Runtime:_throw_error(e, level)
  if not self:_is_current_fibre() then self._driver_depth = 0 end
  error(e, level)
end

function Runtime:_fail(kind, err, fields)
  local e = self:_make_error(kind, err, fields)
  return self:_throw_error(e, fields and fields.level or 2)
end

function Runtime:_check_not_failed(level)
  if self._failed then error(self._failed, level or 2) end
end

function Runtime:_fatal(kind, err, fields)
  fields = fields or {}
  local e = self:_make_error(kind, err, fields)
  e.fatal = true
  self._failed = e
  return self:_throw_error(e, fields.level or 2)
end

function Runtime:failed()
  return self._failed
end

function Runtime:push_scope(scope)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  local f = self._current_fibre
  if not f then error('Runtime:push_scope requires a current fibre', 2) end
  f.scope_stack = f.scope_stack or {}
  local depth = #f.scope_stack + 1
  f.scope_stack[depth] = scope
  current_scope = scope
  return { fibre = f, depth = depth, scope = scope }
end

function Runtime:pop_scope(token)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  local f = self._current_fibre
  if not token or token.fibre ~= f then error('Runtime:pop_scope token does not match current fibre', 2) end
  local stack = f.scope_stack or {}
  if #stack ~= token.depth or stack[token.depth] ~= token.scope then error('Runtime:pop_scope scope stack mismatch', 2) end
  stack[token.depth] = nil
  current_scope = stack[#stack]
  return true
end



function Runtime:with_scope(scope, fn, ...)
  if type(fn) ~= 'function' then error('Runtime:with_scope expects a function', 2) end
  local args = pack(...)
  local token = self:push_scope(scope)
  local results = pack(Protected.pcall(function() return fn(unpack_(args, 1, args.n)) end))
  local pop_ok, pop_err = Protected.pcall(function() return self:pop_scope(token) end)
  if not pop_ok then error(pop_err, 0) end
  if not results[1] then error(results[2], 0) end
  return unpack_(results, 2, results.n)
end

function Runtime:_is_current_fibre()
  local f = self._current_fibre
  if not f then return false end
  return Protected.running() == f.co
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fibre() and (self._driver_depth or 0) == 0 then return true end
  return self:_fail('phase_error', action .. ' may only be called by external driver code', {
    action = action,
    phase = self._phase,
    message = action .. ' may only be called by external driver code',
    level = level or 3,
  })
end

function Runtime:_require_spawn_allowed(level)
  if self:_is_current_fibre() or (self._driver_depth or 0) == 0 then return true end
  return self:_fail('phase_error', 'spawn may not be called from runtime internals', {
    action = 'spawn',
    phase = self._phase,
    message = 'spawn may only be called from external driver code or from a resumed fibre',
    level = level or 3,
  })
end

function Runtime:_require_perform_allowed(level)
  if self:_is_current_fibre() then return true end
  return self:_fail('phase_error', 'perform may only be called by the currently resumed runtime fibre', {
    action = 'perform',
    phase = self._phase,
    message = 'perform may only be called by the currently resumed runtime fibre',
    level = level or 3,
  })
end

local function finish_phase_call(self, old_phase, phase_name, kind, fatal, committed, ok, ...)
  self._phase = old_phase
  if ok then return ... end

  local err = ...
  if type(err) == 'table' and err._fibers_error and not fatal then error(err, 0) end
  if fatal then return self:_fatal(kind, err, { phase = phase_name, committed = committed, level = 0 }) end
  return self:_fail(kind or 'callback_error', err, { phase = phase_name, level = 0 })
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

local function new_fibre(self, fn, name, scope)
  self._next_fibre_id = (self._next_fibre_id or 0) + 1
  return {
    id = self._next_fibre_id,
    co = coroutine.create(fn),
    name = name or ('fiber-' .. tostring(self._next_fibre_id)),
    scope_stack = scope and { scope } or {},
    waiting = nil,
    wait_index = nil,
    state = 'new',
  }
end

function Runtime:_has_ready()
  return self.ready_head <= (self.ready_tail or 0)
end

function Runtime:_push_ready(f)
  assert(f and f.state ~= 'dead', 'cannot ready a dead fibre')
  f.state = 'ready'
  local tail = (self.ready_tail or 0) + 1
  self.ready_tail = tail
  self.ready[tail] = f
end

function Runtime:_pop_ready()
  local head = self.ready_head
  local tail = self.ready_tail or 0
  if head > tail then return nil end
  local f = self.ready[head]
  self.ready[head] = nil
  self.ready_head = head + 1
  if self.ready_head > 64 and self.ready_head > ((tail + 1) / 2) then
    local old, new = self.ready, {}
    local n = 0
    for i = self.ready_head, tail do
      n = n + 1
      new[n] = old[i]
    end
    self.ready = new
    self.ready_head = 1
    self.ready_tail = n
  end
  return f
end

function Runtime:_add_waiting(f, req)
  assert(f and f.state == 'running', 'waiting fibre must be running')
  f.waiting = req
  f.state = 'waiting'
  local waiting = self.waiting
  waiting[#waiting + 1] = f
  f.wait_index = #waiting
end

function Runtime:_remove_waiting(f)
  local i = f and f.wait_index
  if not i then return false end
  local waiting = self.waiting
  local last_i = #waiting
  local last = waiting[last_i]
  waiting[last_i] = nil
  if i ~= last_i then
    waiting[i] = last
    if last then last.wait_index = i end
  end
  f.wait_index = nil
  f.waiting = nil
  return true
end

function Runtime:_retire_fibre(f)
  if not f or f.state == 'dead' then return end
  if self._choice_arbiter and f.id ~= nil then self._choice_arbiter:discard_owner(f.id) end
  if f.wait_index then self:_remove_waiting(f) end
  f.state = 'dead'
  f.waiting = nil
  f.wait_index = nil
  f.co = nil
  f.scope_stack = nil
  self.live_count = (self.live_count or 1) - 1
end

function Runtime:_resume(f, values)
  if f.state == 'waiting' then self:_remove_waiting(f) end
  if f.state == 'dead' then return end

  local co = f.co
  if not co then return self:_retire_fibre(f) end

  f.state = 'running'
  f.waiting = nil

  local old_phase = self:_set_phase('fibre')
  local old_fibre = self._current_fibre
  local old_current_runtime = current_runtime
  local old_current_scope = current_scope
  self._current_fibre = f
  current_runtime = self
  current_scope = f.scope_stack and f.scope_stack[#f.scope_stack] or nil
  local ok, req_or_err = coroutine.resume(co, values)
  current_runtime = old_current_runtime
  current_scope = old_current_scope
  self:_restore_phase(old_phase)
  self._current_fibre = old_fibre

  if not ok then
    local name = f.name
    self:_retire_fibre(f)
    if type(req_or_err) == 'table' and req_or_err._fibers_error then error(req_or_err, 0) end
    self:_fail('fibre_error', req_or_err, { fibre = name, level = 0 })
  end

  if coroutine.status(co) == 'dead' then
    self:_retire_fibre(f)
  else
    self:_add_waiting(f, req_or_err)
  end
end

function Runtime:_spawn_fibre(fn, name, scope)
  local f = new_fibre(self, fn, name, scope)
  self.live_count = (self.live_count or 0) + 1
  self:_push_ready(f)
  return f
end

function Runtime:spawn_raw(fn, name, scope)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  return self:_spawn_fibre(fn, name, scope)
end

function Runtime:_spawn_committed(fn, name, scope)
  self:_check_not_failed(2)
  return self:_spawn_fibre(fn, name, scope)
end

function Runtime:_discharge_interrupt(token, reason)
  Interrupt.raise(token, reason)
  return true
end



function Runtime:pcall(fn, ...)
  self:_check_not_failed(2)
  return Protected.pcall(fn, ...)
end

function Runtime:xpcall(fn, handler, ...)
  self:_check_not_failed(2)
  return Protected.xpcall(fn, handler, ...)
end

function Runtime:perform(opnode, opts)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  opts = opts or {}
  local interrupt = not opts.masked and opts.interrupt or nil
  if interrupt and interrupt.is_raised and interrupt:is_raised() then
    error(Runtime.cancelled(interrupt.reason, interrupt), 0)
  end
  local attempt = { guard_cache = {}, choice_orders = {} }
  local result = coroutine.yield({ op = opnode, attempt = attempt, interrupt = interrupt })
  if Runtime.is_cancelled(result) then error(result, 0) end
  if type(result) ~= 'table' then return nil end

  local vals, post = result.vals or Op._pack(), result.post
  if post then vals = post(vals) end
  return unpack_(vals, 1, vals.n or #vals)
end

local function pending_from_waiting(waiting)
  local pending = {}
  for i = 1, #waiting do
    local f = waiting[i]
    local w = f and f.waiting
    if w and w.op then pending[f.id or i] = { fiber = f, op = w.op, attempt = w.attempt } end
  end
  return pending
end

local function pending_has_any(pending)
  for _ in pairs(pending or {}) do return true end
  return false
end



function Runtime:_find_net_outcome(waiting, opts)
  local pending = pending_from_waiting(waiting)
  if not pending_has_any(pending) then return { tag = 'retry', proof = require('fibers.kernel.retry').permanent('no-pending'), interests = {} }, pending end

  opts = opts or {}
  Resources.invalidate_matured_deadline_frontiers(self)

  local solver, cursor, out
  if opts.max_work then
    local sig = Net.pending_signature and Net.pending_signature(pending) or nil
    local cache = self._net_wait_cache
    if cache and cache.pending_sig == sig and Resources.observer_valid(cache.observer) then
      return cache.out, pending
    elseif cache then
      if cache.observer and cache.observer.dispose then cache.observer:dispose() end
      self._net_wait_cache = nil
    end

    cursor = self:_valid_cursor(pending)
    if cursor then
      solver = cursor.solver
    else
      solver = Net.Solver.new(self, pending)
      cursor = solver:new_cursor()
    end
    out = solver:advance(cursor, opts.max_work)
    if out.tag == 'budget' then
      self._cursor = out.cursor
    else
      self._cursor = nil
      if out.tag ~= 'hit' then
        self._net_wait_cache = { pending_sig = sig, out = out, observer = cursor and cursor:take_observer() or nil }
      else
        if cursor and cursor.dispose then cursor:dispose() end
        self._net_wait_cache = nil
      end
    end
  else
    self._cursor = nil
    self._net_wait_cache = nil
    solver = Net.Solver.new(self, pending)
    out = solver:find_commit_outcome()
  end

  return out, pending
end

function Runtime:_apply_net_world(world, pending)
  local ok, reason = world:commit(self)
  if not ok then return false, reason end


  local single_id = world.single_root_id
  if single_id ~= nil then
    local entry = pending and pending[single_id]
    local f = entry and entry.fiber
    if f then
      local vals, post = world:delivery_for(self, single_id)
      self:_resume(f, pack_perform_result(vals, post))
    end
    return true
  end

  local ids = {}
  for id, _ in pairs(world.roots or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for i = 1, #ids do
    local id = ids[i]
    local entry = pending and pending[id]
    local f = entry and entry.fiber
    if f then
      local vals, post = world:delivery_for(self, id)
      self:_resume(f, pack_perform_result(vals, post))
    end
  end
  return true
end


function Runtime:_deliver_interrupts()
  local delivered = false
  local i = 1
  while i <= #self.waiting do
    local f = self.waiting[i]
    local w = f and f.waiting
    local token = w and w.interrupt
    if token and token.is_raised and token:is_raised() then
      self:_resume(f, Runtime.cancelled(token.reason, token))
      delivered = true
      -- _resume removes f from waiting by swap-with-tail, so inspect this
      -- position again on the next loop.
    else
      i = i + 1
    end
  end
  return delivered
end

function Runtime:_pump_one()
  local f = self:_pop_ready()
  if not f then return false end
  self:_resume(f, nil)
  return true
end

function Runtime:_pump()
  while self:_pump_one() do end
end

function Runtime:_waiting()
  return self.waiting
end

function Runtime:_has_unstarted()
  return self:_has_ready()
end

function Runtime:_valid_cursor(pending)
  local c = self._cursor
  if c and c.is_valid and c:is_valid(self, pending) then return c end
  if c and c.dispose then c:dispose() end
  self._cursor = nil
  return nil
end



-- One externally-drivable scheduler transition.
--
-- Return tags:
--   found   : one transaction was committed and any selected fibres were resumed
--   pending : useful work was performed but no transaction has yet committed, or
--             the option algebra budget was exhausted without mutation
--   quiescent: retry is proved but no actionable external interest is known
--   idle    : all fibres are complete and there is no pending work
--
-- Bounded work is conservative.  If opts.max_work is reached inside the algebra
-- solver, no resource state is mutated and no fibre is resumed; the caller can
-- call step again later with a fresh budget.
function Runtime:_step(opts)
  opts = opts or {}
  if self:_deliver_interrupts() then return { tag = 'pending', kind = 'interrupt' } end

  local waiting = self:_waiting()
  if #waiting == 0 then
    if self:_pump_one() then return { tag = 'pending', kind = 'started' } end
    if (self.live_count or 0) == 0 then return { tag = 'idle', value = true } end
    return { tag = 'pending', kind = 'no-ready-work' }
  end

  local out, pending = self:_find_net_outcome(waiting, opts)

  if out.tag == 'budget' then
    return { tag = 'pending', kind = 'budget', work = out.used }
  end

  local world = out.tag == 'hit' and out.world or nil
  if world and (not world:has_retry() or not self:_has_unstarted()) then
    local ok, reason = self:_apply_net_world(world, pending)
    if ok then return { tag = 'found', value = true, kind = 'commit' } end
    return plan_failure_status(reason)
  end

  if self:_pump_one() then return { tag = 'pending', kind = 'started' } end

  if world then
    local ok, reason = self:_apply_net_world(world, pending)
    if ok then return { tag = 'found', value = true, kind = 'commit' } end
    return plan_failure_status(reason)
  end

  local interests = Interest.summarise(Interest.merge((out and out.interests) or {}))
  if out.tag == 'unknown' then
    if out.reason == 'budget' then return { tag = 'pending', kind = 'budget', interests_incomplete = true } end
    return { tag = 'pending', kind = out.reason or 'unknown', interests = interests, waits = interests }
  end
  if #interests > 0 then return { tag = 'pending', kind = 'wakeup', interests = interests, waits = interests } end
  return { tag = 'quiescent', reason = 'retry without actionable interest' }
end

function Runtime:_run(opts)
  opts = opts or {}
  if opts.max_work then
    -- Bounded mode performs one externally drivable transition, resuming the
    -- private transaction-net cursor if the waiting frontier is unchanged.
    return self:_step(opts)
  end

  self._cursor = nil
  local committed = false
  while true do
    if self:_deliver_interrupts() then committed = true end
    local waiting = self:_waiting()

    if #waiting == 0 then
      if self:_pump_one() then
        -- newly started work may now participate in a world
      elseif (self.live_count or 0) == 0 then
        if committed then return { tag = 'found', value = true } end
        return { tag = 'idle', value = true }
      else
        if committed then return { tag = 'found', value = true } end
        return { tag = 'pending', kind = 'no-ready-work' }
      end
    else
      local out, pending = self:_find_net_outcome(waiting)
      local world = out.tag == 'hit' and out.world or nil
      if world and (not world:has_retry() or not self:_has_unstarted()) then
        local ok, reason = self:_apply_net_world(world, pending)
        if ok then
          committed = true
        elseif not plan_retriable(reason) then
          return plan_failure_status(reason)
        end
      elseif self:_pump_one() then
        -- A not-yet-started public participant may satisfy the primary side of
        -- an or_else; start it before accepting an absence-certified fallback.
      elseif world then
        local ok, reason = self:_apply_net_world(world, pending)
        if ok then
          committed = true
        elseif not plan_retriable(reason) then
          return plan_failure_status(reason)
        end
      else
        local interests = Interest.summarise(Interest.merge((out and out.interests) or {}))
        if out.tag == 'unknown' then
          if committed then return { tag = 'found', value = true } end
          return { tag = 'pending', kind = out.reason or 'unknown', interests = interests, waits = interests }
        end
        if #interests > 0 then
          if committed then return { tag = 'found', value = true } end
          return { tag = 'pending', kind = 'wakeup', interests = interests, waits = interests }
        end
        if committed then return { tag = 'found', value = true } end
        return { tag = 'quiescent', reason = 'retry without actionable interest' }
      end
    end
  end
end


local function finish_driver_call(self, old_depth, old_phase, ok, ...)
  self._driver_depth = old_depth
  self._phase = old_phase
  if ok then return ... end

  local err = ...
  if type(err) == 'table' and err._fibers_error then error(err, 0) end

  local e = self:_make_error('runtime_error', err, { phase = old_phase, level = 0 })
  e.fatal = true
  self._failed = e
  return self:_throw_error(e, 0)
end

function Runtime:step(opts)
  self:_check_not_failed(2)
  self:_require_driver_call('step', 2)
  local old_depth, old_phase = self._driver_depth or 0, self._phase
  self._driver_depth = old_depth + 1
  return finish_driver_call(self, old_depth, old_phase, pcall(self._step, self, opts))
end



function Runtime:run(opts)
  self:_check_not_failed(2)
  self:_require_driver_call('run', 2)
  local old_depth, old_phase = self._driver_depth or 0, self._phase
  self._driver_depth = old_depth + 1
  return finish_driver_call(self, old_depth, old_phase, pcall(self._run, self, opts))
end

return Runtime
