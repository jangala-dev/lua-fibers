local Cursor = require('et.solver.cursor')
local Search = require('et.solver.search')
local CommitPlan = require('et.commit.plan')
local Resource = require('et.resources.protocol')
local Op = require('et.op')
local Runtime = {}
Runtime.__index = Runtime

local unpack_ = table.unpack or unpack

local PERFORM_RESULT = {}

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
  return setmetatable({
    opts = opts,
    fibres = {},
    published_consequences = {},
    stats = { refreshes = 0, steps = 0, algebra_pending = 0 },
    on_consequence = opts.on_consequence or nil,
    _epoch = 0,
    _cursor = nil,
  }, Runtime)
end

function Runtime:_bump_epoch()
  self._cursor = nil
  self._epoch = (self._epoch or 0) + 1
end

function Runtime:_invalidate_cursor()
  self:_bump_epoch()
end

function Runtime:spawn(fn, name)
  self:_invalidate_cursor()
  local co = coroutine.create(fn)
  self.fibres[#self.fibres + 1] = { co = co, name = name or ('fiber-' .. tostring(#self.fibres + 1)), waiting = nil, done = false }
end

function Runtime:perform(opnode)
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

function Runtime:_resume(f, values)
  local ok, req_or_err = coroutine.resume(f.co, values)
  if not ok then error(req_or_err, 0) end
  if coroutine.status(f.co) == 'dead' then
    f.done = true
    f.waiting = nil
  else
    f.waiting = req_or_err
  end
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
    for i = 1, #prepared do Resource.apply_prepared(prepared[i], log) end
  end
  if log and (#log.transaction > 0 or #log.obligation > 0) then
    self.published_consequences[#self.published_consequences + 1] = log
    if self.on_consequence then self.on_consequence(log) end
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
function Runtime:step(opts)
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
    st = cursor:resume(opts.max_work)
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
    world, score, st = Search.solve(self, waiting, opts)
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
    local plan, reason = CommitPlan.try_from_world(self, world, cert_cursor)
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
    local plan, reason = CommitPlan.try_from_world(self, world, cert_cursor)
    if not plan then self:_invalidate_cursor(); return { tag = 'pending', reason = reason or 'stale world' } end
    self:_apply_commit_plan(plan)
    return { tag = 'found', value = true, kind = 'commit' }
  end

  return { tag = 'absent', reason = 'no compatible transaction' }
end

function Runtime:run(opts)
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
      world, score, st = Search.solve(self, waiting, nil)
    end

    if world and (score_is_zero(score) or not self:_has_unstarted()) then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, reason = CommitPlan.try_from_world(self, world, nil)
      if plan then self:_apply_commit_plan(plan) else self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
    elseif self:_pump_one() then
      -- More public participants may make a preferred world available.
    elseif world then
      committed = true
      if #waiting > #world.combo or self:_has_unstarted() then self.stats.refreshes = (self.stats.refreshes or 0) + 1 end
      local plan, reason = CommitPlan.try_from_world(self, world, nil)
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

return Runtime
