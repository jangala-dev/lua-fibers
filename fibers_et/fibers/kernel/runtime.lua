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

    -- Live frontier state.  A live fibre is owned by exactly one of:
    --   ready queue, waiting frontier, or the currently running slot.
    -- Completed fibres are retired immediately and are not kept by the runtime.
    ready = {},
    ready_head = 1,
    ready_tail = 0,
    waiting = {},
    live_count = 0,
    _next_fibre_id = 0,

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
  return source
end

function Runtime:_clear_source(source, ...)
  self:_check_not_failed(2)
  self:_require_driver_call('clear source', 2)
  if not source or source._fibers_kind ~= Source.Kind then error('Runtime:_clear_source expects a Source', 2) end
  SourceState.clear(source, ...)
  self:_invalidate_cursor()
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

function Runtime:readiness(key, name)
  local source = Source.readiness(key, nil, name)
  local feed = {}
  function feed:ready(mode, value)
    if mode == nil then mode = source.mode or 'read' end
    return self._rt:arrive(source, mode, value == nil and true or value)
  end
  function feed:readable(value)
    return self._rt:arrive(source, 'read', value == nil and true or value)
  end
  function feed:writable(value)
    return self._rt:arrive(source, 'write', value == nil and true or value)
  end
  function feed:clear(mode)
    return self._rt:_clear_source(source, mode)
  end
  feed._rt = self
  return source, feed
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

local function new_fibre(self, fn, name, frame)
  self._next_fibre_id = (self._next_fibre_id or 0) + 1
  return {
    id = self._next_fibre_id,
    co = coroutine.create(fn),
    name = name or ('fiber-' .. tostring(self._next_fibre_id)),
    frame = frame,
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
  self:_invalidate_cursor()
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
  self:_invalidate_cursor()
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
  self:_invalidate_cursor()
  return true
end

function Runtime:_retire_fibre(f)
  if not f or f.state == 'dead' then return end
  if f.wait_index then self:_remove_waiting(f) end
  f.state = 'dead'
  f.waiting = nil
  f.wait_index = nil
  f.co = nil
  f.frame = nil
  self.live_count = (self.live_count or 1) - 1
  self:_invalidate_cursor()
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
  local old_current_frame = current_frame
  self._current_fibre = f
  current_runtime = self
  current_frame = f.frame
  local ok, req_or_err = coroutine.resume(co, values)
  current_runtime = old_current_runtime
  current_frame = old_current_frame
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

function Runtime:_spawn_fibre(fn, name, frame)
  local f = new_fibre(self, fn, name, frame)
  self.live_count = (self.live_count or 0) + 1
  self:_push_ready(f)
  return f
end

function Runtime:spawn_raw(fn, name, frame)
  self:_check_not_failed(2)
  self:_require_spawn_allowed(2)
  return self:_spawn_fibre(fn, name, frame)
end

function Runtime:_spawn_committed(fn, name, frame)
  self:_check_not_failed(2)
  return self:_spawn_fibre(fn, name, frame)
end

function Runtime:_discharge_interrupt(token, reason)
  Interrupt.raise(token, reason)
  self:_invalidate_cursor()
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
  local prepared_effects = plan.prepared_effects

  if prepared then
    local old = self:_set_phase('commit')
    for i = 1, #prepared do Resource.apply_prepared(prepared[i]) end
    self:_restore_phase(old)
  end

  if prepared_effects then
    for i = 1, #prepared_effects do
      local pc = prepared_effects[i]
      local entry = {
        kind = pc.kind_name or (pc.kind and pc.kind.name) or tostring(pc.kind),
        key = pc.key,
        payload = pc.payload,
      }
      self:_call_fatal_in_phase('effect', 'effect_error', true, function()
        return pc.discharge(self, entry)
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
    self:_resume(plan.fiber, pack_perform_result(plan.vals, plan.post))
  elseif plan.fibres then
    for i = 1, #plan.fibres do
      local f = plan.fibres[i]
      self:_resume(f, pack_perform_result(plan.vals_list[i], plan.post_list[i]))
    end
  end

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

function Runtime:_valid_cursor(waiting)
  local c = self._cursor
  if c and c.is_valid and c:is_valid(self, waiting) then return c end
  self._cursor = nil
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
  if self:_deliver_interrupts() then return { tag = 'pending', kind = 'interrupt' } end
  local waiting = self:_waiting()

  if #waiting == 0 then
    if self:_pump_one() then return { tag = 'pending', kind = 'started' } end
    if (self.live_count or 0) == 0 then return { tag = 'idle', value = true } end
    return { tag = 'pending', kind = 'no-ready-work' }
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
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      st.waits = Wait.summarise(Wait.merge(st.waits))
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
      if st.kind == 'wakeup' and self:_pump_one() then return { tag = 'pending', kind = 'started' } end
      st.waits = Wait.summarise(Wait.merge(st.waits))
      return st
    end
  end

  -- A positive score means an or_else fallback was selected.  Such a fallback is
  -- not globally justified until every spawned fibre has reached its current
  -- perform point, because a not-yet-started fibre may still satisfy a preferred
  -- primary.
  if world and (score_is_zero(score) or not self:_has_unstarted()) then
    local cert_cursor = self._cursor
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
        return st
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
    if self:_deliver_interrupts() then committed = true end
    local waiting = self:_waiting()
    local world, score, st = nil, nil, nil
    if #waiting == 1 and waiting[1].waiting and waiting[1].waiting.op and waiting[1].waiting.op.kind == 'always' then
      committed = true
      self:_apply_commit_plan(CommitPlan.always(waiting[1]))
    elseif #waiting > 0 then
      world, score, st = Search.solve(self, waiting, nil)
    end

    if world and (score_is_zero(score) or not self:_has_unstarted()) then
      committed = true
        local plan, _reason = CommitPlan.try_from_world(self, world, nil)
      if plan then self:_apply_commit_plan(plan) elseif not plan_retriable(_reason) then return plan_failure_status(_reason) end
    elseif self:_pump_one() then
      -- More public participants may make a preferred world available.
    elseif world then
      committed = true
        local plan, _reason = CommitPlan.try_from_world(self, world, nil)
      if plan then self:_apply_commit_plan(plan) elseif not plan_retriable(_reason) then return plan_failure_status(_reason) end
    elseif st and st.tag == 'pending' then
      st.waits = Wait.summarise(Wait.merge(st.waits))
      if committed and self:_pump_one() then
        -- A committed effect may have spawned fresh work that can satisfy
        -- the current waits.  Continue before reporting quiescence to the
        -- standalone runner.
      elseif committed then
        return { tag = 'found', value = true }
      else
        return st
      end
    else
      if committed then return { tag = 'found', value = true } end
      if (self.live_count or 0) == 0 then return { tag = 'idle', value = true } end
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
