local Cursor = require('et.solver.cursor')
local Search = require('et.solver.search')
local CommitPlan = require('et.commit.plan')
local Resource = require('et.resources.protocol')
local Op = require('et.op')
local Runtime = {}
Runtime.__index = Runtime

local unpack_ = table.unpack or unpack

local PERFORM_RESULT = {}

local RuntimeError = {}
RuntimeError.__index = RuntimeError
RuntimeError.__tostring = function(e) return e.message or tostring(e.cause) end

local function pack_perform_result(vals, post)
  return { _token = PERFORM_RESULT, vals = vals, post = post }
end

local function apply_post(vals, post)
  if post then return post(vals) end
  return vals
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
    _trace_enabled = host.trace or opts.trace or false,
    fibres = {},
    published_consequences = {},
    stats = { refreshes = 0, steps = 0, algebra_pending = 0 },
    on_consequence = opts.on_consequence or host.on_consequence or nil,
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
  local host = self.host or {}
  local now = host.now or self.opts.now
  if now then return now(self) end
  return 0
end

function Runtime:_trace(kind, fields)
  local trace = self.host and self.host.trace or self.opts.trace
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
    _et_error = true,
    kind = kind,
    phase = fields.phase or self._phase,
    fibre = fields.fibre,
    action = fields.action,
    committed = fields.committed,
    message = message,
    cause = err,
  }, RuntimeError)
end

function Runtime:_fail(kind, err, fields)
  local e = self:_make_error(kind, err, fields)
  local errors = self.errors
  if not errors then errors = {}; self.errors = errors end
  errors[#errors + 1] = e
  local handler = self.host and (self.host.on_error or self.host.report_error) or self.opts.on_error
  if handler then handler(e) end
  if not self:_is_current_fibre() then self._driver_depth = 0 end
  error(e, fields and fields.level or 2)
end

function Runtime:_check_not_failed(level)
  if self._failed then error(self._failed, level or 2) end
end

function Runtime:_fatal(kind, err, fields)
  fields = fields or {}
  local e = self:_make_error(kind, err, fields)
  e.fatal = true
  self._failed = e
  local errors = self.errors
  if not errors then errors = {}; self.errors = errors end
  errors[#errors + 1] = e
  local handler = self.host and (self.host.on_error or self.host.report_error) or self.opts.on_error
  if handler then handler(e) end
  if not self:_is_current_fibre() then self._driver_depth = 0 end
  error(e, fields.level or 2)
end

function Runtime:failed()
  return self._failed
end

function Runtime:_is_current_fibre()
  local f = self._current_fibre
  if not f then return false end
  return coroutine.running() == f.co
end

function Runtime:_require_driver_call(action, level)
  if not self:_is_current_fibre() then return true end
  return self:_fail('phase_error', action .. ' may not be called from a resumed fibre', {
    action = action,
    phase = self._phase,
    message = action .. ' may not be called from a resumed fibre; expected external driver code',
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

local function finish_phase_call(self, old_phase, phase_name, kind, ok, ...)
  self._phase = old_phase
  if ok then return ... end

  local err = ...
  if type(err) == 'table' and err._et_error then error(err, 0) end
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
  return finish_phase_call(self, old, name, kind, pcall(fn, ...))
end

local function finish_fatal_phase_call(self, old_phase, phase_name, kind, committed, ok, ...)
  self._phase = old_phase
  if ok then return ... end

  local err = ...
  return self:_fatal(kind, err, { phase = phase_name, committed = committed, level = 0 })
end

function Runtime:_call_fatal_in_phase(name, kind, committed, fn, ...)
  local old = self:_set_phase(name)
  return finish_fatal_phase_call(self, old, name, kind, committed, pcall(fn, ...))
end

function Runtime:_enter_phase(name, fn, ...)
  return self:_call_in_phase(name, 'callback_error', fn, ...)
end

function Runtime:_search_solve(waiting, opts)
  return Search.solve(self, waiting, opts)
end

function Runtime:_cursor_resume(cursor, max_work)
  return cursor:resume(max_work)
end

function Runtime:_prepare_plan(world, cursor)
  return CommitPlan.try_from_world(self, world, cursor)
end

function Runtime:_resume(f, values)
  local old_phase = self:_set_phase('fibre')
  local old_fibre = self._current_fibre
  self._current_fibre = f
  local ok, req_or_err = coroutine.resume(f.co, values)
  self:_restore_phase(old_phase)
  self._current_fibre = old_fibre
  if not ok then
    f.done = true
    f.waiting = nil
    if type(req_or_err) == 'table' and req_or_err._et_error then error(req_or_err, 0) end
    self:_fail('fibre_error', req_or_err, { fibre = f.name, level = 0 })
  end
  if coroutine.status(f.co) == 'dead' then
    f.done = true
    f.waiting = nil
  else
    f.waiting = req_or_err
  end
end

function Runtime:spawn(fn, name)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  self:_invalidate_cursor()
  local co = coroutine.create(fn)
  self.fibres[#self.fibres + 1] = { co = co, name = name or ('fiber-' .. tostring(#self.fibres + 1)), waiting = nil, done = false }
  if self._trace_enabled then self:_trace('fibre.spawn', { fibre = name }) end
end

function Runtime:perform(opnode)
  self:_check_not_failed(2)
  self:_require_perform_allowed(2)
  local attempt = { guard_cache = {}, nack_cache = {} }
  local result = coroutine.yield({ op = opnode, attempt = attempt })
  if type(result) ~= 'table' then return nil end

  local vals, post
  if result._token == PERFORM_RESULT then
    vals = result.vals
    post = result.post
  else
    -- Backward-compatible fallback for tests or callers that directly resume a
    -- suspended runtime fibre with a packed value table.
    vals = result
  end

  vals = apply_post(vals or Op._pack(), post)
  return unpack_(vals, 1, vals.n or #vals)
end

function Runtime:_apply_commit_plan(plan)
  assert(CommitPlan.is_plan(plan), 'expected certified commit plan')

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

  local prepared = plan.prepared_resources
  local log
  if plan.transaction or prepared then
    log = { transaction = plan.transaction or {}, obligation = {} }
  end
  if prepared then
    local old = self:_set_phase('commit')
    for i = 1, #prepared do Resource.apply_prepared(prepared[i], log) end
    self:_restore_phase(old)
  end
  if log and (#log.transaction > 0 or #log.obligation > 0) then
    self.published_consequences[#self.published_consequences + 1] = log
    if self.on_consequence then
      self:_call_fatal_in_phase('consequence', 'consequence_error', true, self.on_consequence, log)
    end
  end

  -- Resource state and transaction consequences are already committed before any
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
  local progressed = true
  while progressed do
    progressed = self:_pump_one()
  end
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
    st = self:_cursor_resume(cursor, opts.max_work)
    if st.tag == 'pending' then
      self.stats.algebra_pending = (self.stats.algebra_pending or 0) + 1
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      self.pending_wakeups = st.waits
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
    world, score, st = self:_search_solve(waiting, opts)
    if st and st.tag == 'pending' then
      self.stats.algebra_pending = (self.stats.algebra_pending or 0) + 1
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      self.pending_wakeups = st.waits
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
    local plan, reason = self:_prepare_plan(world, cert_cursor)
    if not plan then self:_invalidate_cursor(); return { tag = 'pending', reason = reason or 'stale world' } end
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
    local plan, reason = self:_prepare_plan(world, cert_cursor)
    if not plan then self:_invalidate_cursor(); return { tag = 'pending', reason = reason or 'stale world' } end
    self:_apply_commit_plan(plan)
    return { tag = 'found', value = true, kind = 'commit' }
  end

  return { tag = 'absent', reason = 'no compatible transaction' }
end


function Runtime:step(opts)
  self:_check_not_failed(2)
  self:_require_driver_call('step', 2)
  self._driver_depth = (self._driver_depth or 0) + 1
  local st = self:_step(opts)
  self._driver_depth = self._driver_depth - 1
  return st
end

function Runtime:_run(opts)
  opts = opts or {}
  if opts.max_work then
    local committed = false
    while true do
      local st = self:step(opts)
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
    local world, score, st = nil, nil, nil
    if #waiting == 1 and waiting[1].waiting and waiting[1].waiting.op and waiting[1].waiting.op.kind == 'always' then
      committed = true
      self:_apply_commit_plan(CommitPlan.always(waiting[1]))
    elseif #waiting > 0 then
      world, score, st = self:_search_solve(waiting, nil)
    end

    if world and (score_is_zero(score) or not self:_has_unstarted()) then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, _reason = self:_prepare_plan(world, nil)
      if plan then self:_apply_commit_plan(plan) else self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
    elseif self:_pump_one() then
      -- More public participants may make a preferred world available.
    elseif world then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, _reason = self:_prepare_plan(world, nil)
      if plan then self:_apply_commit_plan(plan) else self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
    elseif st and st.tag == 'pending' then
      self.pending_wakeups = st.waits
      if committed then return { tag = 'found', value = true } end
      return st
    else
      if committed then return { tag = 'found', value = true } end
      return { tag = 'absent', reason = 'no compatible transaction' }
    end
  end
end


function Runtime:run(opts)
  self:_check_not_failed(2)
  self:_require_driver_call('run', 2)
  self._driver_depth = (self._driver_depth or 0) + 1
  local st = self:_run(opts)
  self._driver_depth = self._driver_depth - 1
  return st
end

return Runtime
