local Cursor = require('fibers.kernel.solver.cursor')
local Search = require('fibers.kernel.solver.search')
local CommitPlan = require('fibers.kernel.commit.plan')
local Resource = require('fibers.kernel.resources.protocol')
local Op = require('fibers.base.op')
local Wait = require('fibers.kernel.wait')
local Source = require('fibers.base.source')
local SourceState = require('fibers.internal.source_state')
local Interrupt = require('fibers.internal.interrupt')
local Protected = require('fibers.kernel.protected')
local Runtime = {}
Runtime.__index = Runtime

local current_runtime = nil
local current_frame = nil

function Runtime.current()
  return current_runtime
end

function Runtime._current_frame()
  return current_frame
end

local unpack_ = table.unpack or unpack

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
  return setmetatable({
    opts = opts,
    host = host,
    fibres = {},
    published_consequences = {},
    stats = { refreshes = 0, steps = 0, algebra_pending = 0 },
    _epoch = 0,
    _cursor = nil,
    _phase = 'external',
    _current_fibre = nil,
    _driver_depth = 0,
    _failed = nil,
  }, Runtime)
end

function Runtime:_bump_epoch()
  self._cursor = nil
  self._epoch = (self._epoch or 0) + 1
end

function Runtime:_invalidate_cursor()
  self:_bump_epoch()
end

function Runtime:now()
  local now = self.host.now or self.opts.now
  if now then return now(self) end
  return 0
end

-- Host/source arrival boundary.  External facts enter through the Runtime,
-- which updates the source and invalidates bounded search in one operation.
function Runtime:arrive(source, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('arrive', 2)
  if not source or source._fibers_kind ~= Source.Kind then error('Runtime:arrive expects a Source', 2) end
  SourceState.arrive(source, ...)
  self:_invalidate_cursor()
  self:_trace('source.arrive', { source = source.name or source._fibers_id, source_id = source._fibers_id })
  return source
end

function Runtime:_clear_source(source, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('clear source', 2)
  if not source or source._fibers_kind ~= Source.Kind then error('Runtime:_clear_source expects a Source', 2) end
  SourceState.clear(source, ...)
  self:_invalidate_cursor()
  self:_trace('source.clear', { source = source.name or source._fibers_id, source_id = source._fibers_id })
  return source
end

function Runtime:signal(name)
  local source = Source.signal(name)
  return source, {
    set = function(_feed, ...) return self:arrive(source, ...) end,
    clear = function(_feed) return self:_clear_source(source) end,
  }
end

function Runtime:queue_source(name)
  local source = Source.queue(name)
  return source, {
    push = function(_feed, ...) return self:arrive(source, ...) end,
    clear = function(_feed) return self:_clear_source(source) end,
  }
end

function Runtime:readiness_source(key, mode, name)
  local source = Source.readiness(key, mode, name)
  return source, {
    set_ready = function(_feed, a, b) return self:arrive(source, a, b) end,
    clear_ready = function(_feed, m) return self:_clear_source(source, m) end,
  }
end

function Runtime:_trace(kind, fields)
  local trace = self.host.trace or self.opts.trace
  if not trace then return end
  fields = fields or {}
  fields.kind = kind
  fields.phase = self._phase
  fields.epoch = self._epoch
  trace(fields)
end

function Runtime:_make_error(kind, err, fields)
  fields = fields or {}
  local message = fields.message or tostring(err)
  return setmetatable({
    _fibers_error = true,
    kind = kind,
    phase = fields.phase or self._phase,
    fibre = fields.fibre,
    action = fields.action,
    committed = fields.committed,
    message = message,
    cause = err,
  }, RuntimeError)
end

function Runtime:_throw_error(e, level)
  local errors = self.errors
  if not errors then errors = {}; self.errors = errors end
  errors[#errors + 1] = e
  local handler = self.host and (self.host.on_error or self.host.report_error) or self.opts.on_error
  if handler then handler(e) end
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

function Runtime:_resume(f, values)
  local old_phase = self:_set_phase('fibre')
  local old_fibre = self._current_fibre
  local old_current_runtime = current_runtime
  local old_current_frame = current_frame
  self._current_fibre = f
  current_runtime = self
  current_frame = f.frame
  local ok, req_or_err = coroutine.resume(f.co, values)
  current_runtime = old_current_runtime
  current_frame = old_current_frame
  self:_restore_phase(old_phase)
  self._current_fibre = old_fibre
  if not ok then
    f.done = true
    f.waiting = nil
    if type(req_or_err) == 'table' and req_or_err._fibers_error then error(req_or_err, 0) end
    self:_fail('fibre_error', req_or_err, { fibre = f.name, level = 0 })
  end
  if coroutine.status(f.co) == 'dead' then
    f.done = true
    f.waiting = nil
  else
    f.waiting = req_or_err
  end
end

function Runtime:spawn_raw(fn, name, frame)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  self:_invalidate_cursor()
  local co = coroutine.create(fn)
  self.fibres[#self.fibres + 1] = { co = co, name = name or ('fiber-' .. tostring(#self.fibres + 1)), waiting = nil, done = false, frame = frame }
  self:_trace('fibre.spawn_raw', { fibre = name })
end

function Runtime:_spawn_committed(fn, name, frame)
  self:_check_not_failed(2)
  self:_invalidate_cursor()
  local co = coroutine.create(fn)
  self.fibres[#self.fibres + 1] = { co = co, name = name or ('fiber-' .. tostring(#self.fibres + 1)), waiting = nil, done = false, frame = frame }
  self:_trace('fibre.spawn_committed', { fibre = name })
end

function Runtime:_note_wake(wake, _log)
  self.published_wakes = self.published_wakes or {}
  self.published_wakes[#self.published_wakes + 1] = wake
end

function Runtime:_publish_interrupt(token, reason)
  Interrupt.raise(token, reason)
  self:_invalidate_cursor()
  return true
end

function Runtime:pending_wait_summary()
  return Wait.summarise(self.pending_waits or self.pending_wakeups or {})
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
  local attempt = { guard_cache = {}, nack_cache = {} }
  local result = coroutine.yield({ op = opnode, attempt = attempt, interrupt = interrupt })
  if Runtime.is_cancelled(result) then error(result, 0) end
  if type(result) ~= 'table' then return nil end

  local vals, post = result.vals or Op._pack(), result.post
  if post then vals = post(vals) end
  return unpack_(vals, 1, vals.n or #vals)
end

function Runtime:_apply_commit_plan(plan)
  assert(CommitPlan.is_plan(plan), 'expected certified commit plan')

  local prepared = plan.prepared_resources
  local prepared_consequences = plan.prepared_consequences
  local log

  if prepared or prepared_consequences then
    log = { obligation = {} }
  end

  if prepared then
    local old = self:_set_phase('commit')
    for i = 1, #prepared do Resource.apply_prepared(prepared[i], log) end
    self:_restore_phase(old)
  end

  if log and (#log.obligation > 0 or (prepared_consequences and #prepared_consequences > 0)) then
    self.published_consequences[#self.published_consequences + 1] = log
  end

  if prepared_consequences then
    for i = 1, #prepared_consequences do
      local pc = prepared_consequences[i]
      local entry = {
        kind = pc.kind_name or (pc.kind and pc.kind.name) or tostring(pc.kind),
        key = pc.key,
        payload = pc.payload,
      }
      log.obligation[#log.obligation + 1] = entry
      self:_call_fatal_in_phase('consequence', 'consequence_error', true, function()
        return pc.publish(self, entry, log)
      end)
    end
  end

  local selected, lost = plan.selected_nacks, plan.lost_nacks
  if selected then
    for i = 1, #selected do
      local ref = selected[i]
      if ref.state == 'pending' then ref.state = 'selected' end
    end
  end
  if lost then
    for i = 1, #lost do
      local ref = lost[i]
      if ref.state == 'pending' then ref.state = 'lost' end
    end
  end

  -- Resource state and transaction obligations are already committed before any
  -- selected fibre is resumed.  Invalidate cached search state before post-commit
  -- wrap code can run, yield, or fail.
  self:_bump_epoch()

  if plan.fiber then
    plan.fiber.waiting = nil
    self:_resume(plan.fiber, pack_perform_result(plan.vals, plan.post))
  elseif plan.fibres then
    for i = 1, #plan.fibres do plan.fibres[i].waiting = nil end
    for i = 1, #plan.fibres do
      local f = plan.fibres[i]
      self:_resume(f, pack_perform_result(plan.vals_list[i], plan.post_list[i]))
    end
  end

end


function Runtime:_deliver_interrupts(waiting)
  local delivered = false
  waiting = waiting or self:_waiting()
  for i = 1, #waiting do
    local f = waiting[i]
    local w = f.waiting
    local token = w and w.interrupt
    if token and token.is_raised and token:is_raised() then
      f.waiting = nil
      self:_resume(f, Runtime.cancelled(token.reason, token))
      delivered = true
    end
  end
  if delivered then self:_bump_epoch() end
  return delivered
end

function Runtime:_pump_one()
  for i = 1, #self.fibres do
    local f = self.fibres[i]
    if not f.done and not f.waiting then
      self:_resume(f, nil)
      self:_bump_epoch()
      return true
    end
  end
  return false
end

function Runtime:_pump()
  while self:_pump_one() do end
end

function Runtime:_waiting()
  local xs = {}
  for i = 1, #self.fibres do
    local f = self.fibres[i]
    if not f.done and f.waiting then xs[#xs + 1] = f end
  end
  return xs
end

function Runtime:_has_unstarted()
  for i = 1, #self.fibres do
    local f = self.fibres[i]
    if not f.done and not f.waiting then return true end
  end
  return false
end

function Runtime:_valid_cursor(waiting)
  local c = self._cursor
  if c and c.is_valid and c:is_valid(self, waiting) then return c end
  self._cursor = nil
  return nil
end

function Runtime:cursor_stats()
  local c = self._cursor
  if c and c.stats_snapshot then return c:stats_snapshot() end
  return nil
end

-- One externally-drivable scheduler transition.
--
-- Return tags:
--   found   : one transaction was committed and any selected fibres were resumed
--   pending : useful work was performed but no transaction has yet committed, or
--             the optional algebra budget was exhausted without mutation
--   absent  : no compatible transaction exists for the current waiting set
--   idle    : all fibres are complete and there is no pending work
--
-- Bounded work is conservative.  If opts.max_work is reached inside the algebra
-- solver, no resource state is mutated and no fibre is resumed; the caller can
-- call step again later with a fresh budget.
function Runtime:_step(opts)
  opts = opts or {}
  self.stats.steps = (self.stats.steps or 0) + 1

  local waiting = self:_waiting()
  if self:_deliver_interrupts(waiting) then return { tag = 'pending', kind = 'interrupt' } end

  if #waiting == 0 then
    if self:_pump_one() then return { tag = 'pending', kind = 'started' } end
    return { tag = 'idle', value = true }
  end

  local world, score, st = nil, nil, nil
  if #waiting == 1 and waiting[1].waiting and waiting[1].waiting.op and waiting[1].waiting.op.kind == 'always' then
    self:_apply_commit_plan(CommitPlan.always(waiting[1]))
    return { tag = 'found', value = true, kind = 'commit' }
  end

  if opts.max_work then
    local cursor = self:_valid_cursor(waiting)
    if not cursor then
      cursor = Cursor.new(self, waiting, opts)
      self._cursor = cursor
    end
    st = cursor:resume(opts.max_work)
    if st.tag == 'pending' then
      self.stats.algebra_pending = (self.stats.algebra_pending or 0) + 1
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      self.pending_wakeups = Wait.merge(st.waits)
      self.pending_waits = self.pending_wakeups
      return st
    elseif st.tag == 'committable' then
      world, score = st.world, st.score
    elseif st.tag == 'absent' then
      self._cursor = nil
      if self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      return st
    else
      return st
    end
  else
    self._cursor = nil
    world, score, st = Search.solve(self, waiting, opts)
    if st and st.tag == 'pending' then
      self.stats.algebra_pending = (self.stats.algebra_pending or 0) + 1
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      self.pending_wakeups = Wait.merge(st.waits)
      self.pending_waits = self.pending_wakeups
      return st
    end
  end

  -- A positive score means an or_else fallback was selected.  Such a fallback is
  -- not globally justified until every spawned fibre has reached its current
  -- perform point, because a not-yet-started fibre may still satisfy a preferred
  -- primary.
  if world and (score_is_zero(score) or not self:_has_unstarted()) then
    local cert_cursor = self._cursor
    if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
    local plan, reason = CommitPlan.try_from_world(self, world, cert_cursor)
    if not plan then self:_invalidate_cursor(); return plan_failure_status(reason) end
    self._cursor = nil
    self:_apply_commit_plan(plan)
    return { tag = 'found', value = true, kind = 'commit' }
  end

  self._cursor = nil
  if self:_pump_one() then
    return { tag = 'pending', kind = 'started' }
  end

  if world then
    local cert_cursor = self._cursor
    if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
    local plan, reason = CommitPlan.try_from_world(self, world, cert_cursor)
    if not plan then self:_invalidate_cursor(); return plan_failure_status(reason) end
    self:_apply_commit_plan(plan)
    return { tag = 'found', value = true, kind = 'commit' }
  end

  return { tag = 'absent', reason = 'no compatible transaction' }
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

function Runtime:_run(opts)
  opts = opts or {}
  if opts.max_work then
    local committed = false
    while true do
      local st = self:_step(opts)
      if st.tag == 'found' then
        committed = true
      elseif st.tag == 'pending' then
        return st
      elseif st.tag == 'idle' then
        if committed then return { tag = 'found', value = true } end
        return { tag = 'absent', reason = 'no live work' }
      elseif st.tag == 'absent' then
        if committed then return { tag = 'found', value = true } end
        return st
      else
        return st
      end
    end
  end

  self._cursor = nil
  local committed = false
  while true do
    local waiting = self:_waiting()
    if self:_deliver_interrupts(waiting) then
      committed = true
      waiting = self:_waiting()
    end
    local world, score, st = nil, nil, nil
    if #waiting == 1 and waiting[1].waiting and waiting[1].waiting.op and waiting[1].waiting.op.kind == 'always' then
      committed = true
      self:_apply_commit_plan(CommitPlan.always(waiting[1]))
    elseif #waiting > 0 then
      world, score, st = Search.solve(self, waiting, nil)
    end

    if world and (score_is_zero(score) or not self:_has_unstarted()) then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, _reason = CommitPlan.try_from_world(self, world, nil)
      if plan then self:_apply_commit_plan(plan) elseif plan_retriable(_reason) then self.stats.refreshes = (self.stats.refreshes or 0) + 1 else return plan_failure_status(_reason) end
    elseif self:_pump_one() then
      -- More public participants may make a preferred world available.
    elseif world then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, _reason = CommitPlan.try_from_world(self, world, nil)
      if plan then self:_apply_commit_plan(plan) elseif plan_retriable(_reason) then self.stats.refreshes = (self.stats.refreshes or 0) + 1 else return plan_failure_status(_reason) end
    elseif st and st.tag == 'pending' then
      self.pending_wakeups = Wait.merge(st.waits)
      self.pending_waits = self.pending_wakeups
      if committed and self:_pump_one() then
        -- A committed consequence may have spawned fresh work that can satisfy
        -- the current waits.  Continue before reporting quiescence to the
        -- standalone runner.
      elseif committed then
        return { tag = 'found', value = true }
      else
        return st
      end
    else
      if committed then return { tag = 'found', value = true } end
      return { tag = 'absent', reason = 'no compatible transaction' }
    end
  end
end


function Runtime:run(opts)
  self:_check_not_failed(2)
  self:_require_driver_call('run', 2)
  local old_depth, old_phase = self._driver_depth or 0, self._phase
  self._driver_depth = old_depth + 1
  return finish_driver_call(self, old_depth, old_phase, pcall(self._run, self, opts))
end

return Runtime
