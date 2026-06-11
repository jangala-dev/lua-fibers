local Result = require('fibers.kernel.algebra.result')
local Candidate = require('fibers.kernel.algebra.candidate')
local Eval = require('fibers.kernel.algebra.eval')
local Rendezvous = require('fibers.kernel.solver.rendezvous')
local State = require('fibers.kernel.solver.state')
local World = require('fibers.kernel.solver.world')
local CommitPlan = require('fibers.kernel.commit.plan')
local ObservationJournal = require('fibers.kernel.observation_journal')

local clone_candidate = Candidate.clone
local process_one_deferred = Eval.process_one_deferred
local normalise_result = Eval.normalise_result
local eval_op = Eval.eval_op
local new_rendezvous_index = Rendezvous.new_index
local find_rendezvous_choices = Rendezvous.find_choices
local closed_world = State.closed_world
local state_with_deferred_branch = State.with_deferred_branch
local state_with_match = State.with_match

local Engine = {}
Engine.__index = Engine

local function combo_order_sum(combo)
  return State.combo_order_sum(combo)
end

local function combo_better(combo, _pref, best, _best_pref, best_order)
  if not best then return true end
  return combo_order_sum(combo) < best_order
end

local function sort_candidates(cs)
  table.sort(cs, function(a, b) return (a.order or 0) < (b.order or 0) end)
end

local function assign_candidate_order(sctx, c)
  sctx.order = (sctx.order or 0) + 1
  c.order = sctx.order
end

local function status_from_waits(waits)
  if waits and #waits > 0 then
    return { tag = 'pending', kind = 'wakeup', reason = 'waiting for external wakeup', waits = waits }
  end
  return { tag = 'absent', reason = 'no compatible transaction' }
end

local function copy_open(open, id)
  local t = {}
  if open then for k, v in pairs(open) do t[k] = v end end
  if id then t[id] = true end
  return t
end

local function open_key(open)
  if not open then return '' end
  local xs = {}
  for k in pairs(open) do xs[#xs + 1] = k end
  table.sort(xs)
  return table.concat(xs, '|')
end

local function residual_score(open, pref)
  if not open then return pref end
  local n = 0
  for _ in pairs(open) do n = n + 1 end
  if n == 0 then return pref end
  return { n }
end

function Engine.new(rt, waiting, opts)
  return setmetatable({
    rt = rt,
    waiting = waiting,
    opts = opts or {},

    phase = 'build-candidates',
    lists = {},
    build_i = 1,
    total_endpoints = 0,
    total_candidates = 0,
    rendezvous_index = nil,

    seed_i = 1,
    seed_j = 1,
    stack = {},

    best = nil,
    best_pref = nil,
    best_order = nil,
    waits = nil,
    residuals = nil,
    terminal_waits = nil,
    residual_open = nil,
    residual_counts = {},
    residual_queue = {},
    residual_seen = { [''] = true },
    residual_head = 1,

    work = 0,
    max_work = math.huge,
    stats = { seeds_seen = 0, frames = 0, solutions = 0 },
    order = 0,
    observations = nil,
  }, Engine)
end

function Engine:reset_search_space(open)
  self.phase = 'build-candidates'
  self.lists = {}
  self.build_i = 1
  self.total_endpoints = 0
  self.total_candidates = 0
  self.rendezvous_index = nil
  self.seed_i = 1
  self.seed_j = 1
  self.stack = {}
  self.best = nil
  self.best_pref = nil
  self.best_order = nil
  self.waits = nil
  self.residuals = nil
  self.residual_counts = {}
  self.residual_open = open
end

function Engine:enqueue_residuals()
  local rs = self.residuals
  if not rs or #rs == 0 then return end
  table.sort(rs, function(a, b) return (a.order or 0) < (b.order or 0) end)
  for i = 1, #rs do
    local open = copy_open(self.residual_open, rs[i].id)
    local key = open_key(open)
    if not self.residual_seen[key] then
      self.residual_seen[key] = true
      self.residual_queue[#self.residual_queue + 1] = { open = open }
    end
  end
end

function Engine:begin_next_residual_env()
  if self.residual_head > #self.residual_queue then return false end
  local env = self.residual_queue[self.residual_head]
  self.residual_head = self.residual_head + 1
  self:reset_search_space(env.open)
  return true
end

function Engine:tick(n)
  self.work = self.work + (n or 1)
  if self.work > self.max_work then return false end
  return true
end

local function build_one(self)
  local f = self.waiting[self.build_i]
  local ctx = ObservationJournal.attach({
    rt = self.rt,
    attempt = f.waiting.attempt,
    overlay = nil,
    origin = nil,
    fiber_id = self.build_i,
    residual_open = self.residual_open,
    residual_counts = self.residual_counts,
  }, self)
  local r = normalise_result(eval_op(f.waiting.op, ctx), ctx)
  self.waits = Result._unique_append(self.waits, r.waits)
  self.residuals = Result._unique_append(self.residuals, r.residuals)
  local cs = r.cands
  for j = 1, #cs do
    cs[j].fiber = f
    assign_candidate_order(self, cs[j])
    self.total_endpoints = self.total_endpoints + #(cs[j].endpoints or {})
  end
  self.total_candidates = self.total_candidates + #cs
  if #cs > 1 then sort_candidates(cs) end
  self.lists[self.build_i] = cs
  self.build_i = self.build_i + 1
end

function Engine:build_some()
  while self.build_i <= #self.waiting do
    if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = self.phase, work = self.work } end
    build_one(self)
  end
  self.phase = 'build-index'
  return nil
end

function Engine:build_all()
  while self.build_i <= #self.waiting do build_one(self) end
  self.phase = 'build-index'
end

function Engine:build_index_some()
  if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = self.phase, work = self.work } end
  self.rendezvous_index = new_rendezvous_index(self.lists, self.total_endpoints, self.total_candidates)
  self.phase = 'search'
  return nil
end

function Engine:build_index_all()
  self.rendezvous_index = new_rendezvous_index(self.lists, self.total_endpoints, self.total_candidates)
  self.phase = 'search'
end

function Engine:next_seed()
  while self.seed_i <= #self.lists do
    local list = self.lists[self.seed_i] or {}
    if self.seed_j <= #list then
      local seed = list[self.seed_j]
      self.seed_j = self.seed_j + 1
      self.stats.seeds_seen = self.stats.seeds_seen + 1
      return seed
    end
    self.seed_i = self.seed_i + 1
    self.seed_j = 1
  end
  return nil
end

function Engine:push_seed(seed)
  local selected = { clone_candidate(seed) }
  local selected_by_fiber = {}
  if selected[1].fiber then selected_by_fiber[selected[1].fiber] = true end
  self.stack[#self.stack + 1] = { phase = 'enter', sel = selected, by = selected_by_fiber, seed_order = seed.order or 0 }
end

function Engine:push_state(sel, by, seed_order)
  self.stack[#self.stack + 1] = { phase = 'enter', sel = sel, by = by, seed_order = seed_order or 0 }
end

function Engine:record_solution(combo)
  local w = closed_world(combo)
  if not w then return nil end

  -- Commit preparation is side-effect-free trusted machinery.  Running it here
  -- lets structured resource/consequence refusals reject this candidate world
  -- and allows search to continue to other worlds rather than returning a
  -- non-committable plan to the public driver.
  local plan, _reason = CommitPlan.try_from_world(self.rt, w, nil)
  if not plan then return nil end
  w.prepared_plan = plan

  self.stats.solutions = self.stats.solutions + 1
  if combo_better(w.combo, w.pref, self.best and self.best.combo, self.best_pref, self.best_order) then
    self.best, self.best_pref, self.best_order = w, w.pref, w.order
  end
  if World.is_committable(w) then
    return { tag = 'committable', world = w, score = residual_score(self.residual_open, w.pref) }
  end
  return nil
end

local function advance_enter(self, frame)
  self.stats.frames = self.stats.frames + 1
  if not State.resource_ok(frame.sel, false) then
    self.stack[#self.stack] = nil
    return nil
  end

  for ci = 1, #frame.sel do
    local branches = process_one_deferred(frame.sel[ci], ObservationJournal.attach({ rt = self.rt }, self))
    if branches then
      self.waits = Result._unique_append(self.waits, branches.waits)
      self.residuals = Result._unique_append(self.residuals, branches.residuals)
      frame.phase = 'deferred'
      frame.ci = ci
      frame.branches = branches.cands
      frame.bi = 1
      return nil
    end
  end

  local ci, ei, _e, matches = find_rendezvous_choices(frame.sel, frame.by, self.lists, frame.seed_order or 0, self.rendezvous_index)
  if not ci then
    local combo = frame.sel
    self.stack[#self.stack] = nil
    return self:record_solution(combo)
  end
  if #matches == 0 then
    self.stack[#self.stack] = nil
    return nil
  end
  frame.phase = 'matches'
  frame.ci = ci
  frame.ei = ei
  frame.matches = matches
  frame.mi = 1
  return nil
end

function Engine:advance_enter_some(frame)
  if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = 'search', work = self.work } end
  return advance_enter(self, frame)
end

local function advance_deferred(self, frame)
  if frame.bi > #frame.branches then
    self.stack[#self.stack] = nil
    return nil
  end
  local branch = frame.branches[frame.bi]
  frame.bi = frame.bi + 1
  local ns, nb = state_with_deferred_branch(frame.sel, frame.by, frame.ci, branch)
  if ns then self:push_state(ns, nb, frame.seed_order) end
  return nil
end

function Engine:advance_deferred_some(frame)
  if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = 'search', work = self.work } end
  return advance_deferred(self, frame)
end

local function advance_match(self, frame)
  if frame.mi > #frame.matches then
    self.stack[#self.stack] = nil
    return nil
  end
  local m = frame.matches[frame.mi]
  frame.mi = frame.mi + 1
  local ns, nb = state_with_match(frame.sel, frame.by, frame.ci, frame.ei, m)
  if ns then self:push_state(ns, nb, frame.seed_order) end
  return nil
end

function Engine:advance_match_some(frame)
  if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = 'search', work = self.work } end
  return advance_match(self, frame)
end

function Engine:finish_env_or_continue(yield_residual)
  if self.best then
    self.phase = 'done'
    return { tag = 'committable', world = World.with_absence_proved(self.best), score = residual_score(self.residual_open, self.best_pref) }
  end
  if self.residuals and #self.residuals > 0 then
    self:enqueue_residuals()
    if self:begin_next_residual_env() then
      if yield_residual then return { tag = 'pending', reason = 'residual fallback opened', kind = 'residual' } end
      return { tag = 'again' }
    end
  end
  self.terminal_waits = Result._unique_append(self.terminal_waits, self.waits)
  if self:begin_next_residual_env() then
    if yield_residual then return { tag = 'pending', reason = 'next residual environment', kind = 'residual' } end
    return { tag = 'again' }
  end
  self.phase = 'done'
  return status_from_waits(self.terminal_waits)
end

function Engine:search_some()
  while true do
    if #self.stack == 0 then
      if not self:tick(1) then return { tag = 'pending', reason = 'work budget exhausted', phase = 'search', work = self.work } end
      local seed = self:next_seed()
      if not seed then return self:finish_env_or_continue(true) end
      if #(seed.endpoints or {}) == 0 and #(seed.deferred or {}) == 0 then
        local st = self:record_solution({ seed })
        if st then return st end
      else
        self:push_seed(seed)
      end
    else
      local frame = self.stack[#self.stack]
      local st
      if frame.phase == 'enter' then
        st = self:advance_enter_some(frame)
      elseif frame.phase == 'deferred' then
        st = self:advance_deferred_some(frame)
      elseif frame.phase == 'matches' then
        st = self:advance_match_some(frame)
      else
        error('unknown engine frame phase ' .. tostring(frame.phase))
      end
      if st then return st end
    end
  end
end

function Engine:search_all()
  while true do
    if #self.stack == 0 then
      local seed = self:next_seed()
      if not seed then
        local st = self:finish_env_or_continue(false)
        if st then return st end
      elseif #(seed.endpoints or {}) == 0 and #(seed.deferred or {}) == 0 then
        local st = self:record_solution({ seed })
        if st then return st end
      else
        self:push_seed(seed)
      end
    else
      local frame = self.stack[#self.stack]
      local st
      if frame.phase == 'enter' then
        st = advance_enter(self, frame)
      elseif frame.phase == 'deferred' then
        st = advance_deferred(self, frame)
      elseif frame.phase == 'matches' then
        st = advance_match(self, frame)
      else
        error('unknown engine frame phase ' .. tostring(frame.phase))
      end
      if st then return st end
    end
  end
end

function Engine:resume(max_work)
  self.max_work = max_work or math.huge
  self.work = 0
  while true do
    if self.phase == 'build-candidates' then
      local st = self:build_some()
      if st then return st end
    elseif self.phase == 'build-index' then
      local st = self:build_index_some()
      if st then return st end
    elseif self.phase == 'search' then
      return self:search_some()
    elseif self.phase == 'done' then
      if self.best then return { tag = 'committable', world = World.with_absence_proved(self.best), score = residual_score(self.residual_open, self.best_pref) } end
      return status_from_waits(self.terminal_waits or self.waits)
    else
      error('unknown engine phase ' .. tostring(self.phase))
    end
  end
end

function Engine:run_unbounded()
  while true do
    if self.phase == 'build-candidates' then
      self:build_all()
    elseif self.phase == 'build-index' then
      self:build_index_all()
    elseif self.phase == 'search' then
      local st = self:search_all()
      if st.tag == 'committable' then return st.world, st.score end
      if st.tag ~= 'again' then return nil, nil, st end
    elseif self.phase == 'done' then
      if self.best then return World.with_absence_proved(self.best), residual_score(self.residual_open, self.best_pref) end
      return nil, nil, status_from_waits(self.terminal_waits or self.waits)
    else
      error('unknown engine phase ' .. tostring(self.phase))
    end
  end
end

function Engine.solve_unbounded(rt, waiting, opts)
  return Engine.new(rt, waiting, opts):run_unbounded()
end

function Engine:stats_snapshot()
  return {
    phase = self.phase,
    work = self.work,
    build_i = self.build_i,
    seed_i = self.seed_i,
    seed_j = self.seed_j,
    stack_depth = #self.stack,
    seeds_seen = self.stats.seeds_seen,
    frames = self.stats.frames,
    solutions = self.stats.solutions,
    waits = #(self.waits or {}),
    residuals = #(self.residuals or {}),
    observations = self.observations and self.observations:summary() or nil,
    residual_queue = #self.residual_queue,
    best_pref = self.best_pref,
  }
end

Engine.combo_order_sum = combo_order_sum
Engine.combo_better = combo_better
Engine.sort_candidates = sort_candidates
Engine.assign_candidate_order = assign_candidate_order
Engine.status_from_waits = status_from_waits
Engine.residual_score = residual_score

return Engine
