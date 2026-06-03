-- runtime.lua
--
-- Coroutine runtime and host-integration shell for the Eventful
-- Transactions core.  etfcore.lua owns the algebra, proof frontier, proof
-- search and commit-plan types; this module owns fibres, parked attempts,
-- settlement cells, retained external waits, bounded stepping and standalone
-- running policy.

local core = require('etfcore')
local Engine = core._engine

local pack = Engine.pack
local unpack_pack = Engine.unpack_pack
local empty_evidence = Engine.empty_evidence
local run_in_phase = Engine.run_in_phase
local in_search_phase = Engine.in_search_phase
local with_current_task = Engine.with_current_task

local RootAttempt = Engine.RootAttempt
local SettlementCell = Engine.SettlementCell
local ExpansionContext = Engine.ExpansionContext
local PartialProof = Engine.PartialProof
local ProofSearch = Engine.ProofSearch
local JudgementContext = Engine.JudgementContext

local expand_expr = Engine.expand_expr
local expand_top_frame = Engine.expand_top_frame
local frame_collect_publishable_settlements = Engine.frame_collect_publishable_settlements
local frame_collect_external_waits = Engine.frame_collect_external_waits
local forced_decisions_for_obligation = Engine.forced_decisions_for_obligation
local committable_search_key = Engine.committable_search_key

local function require_judgement(method_name, judgement)
  if not (type(judgement) == 'table' and judgement.__is_judgement) then
    error(method_name .. ' requires an explicit JudgementContext', 2)
  end
  return judgement
end

local function default_descriptor_handler(event)
  if event.tag == 'ledger.move' then
    print(string.format('[commit event] move %s: %s -> %s', tostring(event.item), tostring(event.from), tostring(event.to)))
  elseif event.tag == 'ledger.close' then
    print(string.format('[commit event] close %s reason=%s', tostring(event.owner), tostring(event.reason)))
  else
    print('[commit event] ' .. tostring(event.tag))
  end
end

local Runtime = {}
Runtime.__index = Runtime

function Runtime.new(opts)
  opts = opts or {}
  return setmetatable({
    runnable = {},
    waiting = {},
    waiting_set = {},
    next_task_id = 0,
    generation = 0,
    settlements = {},
    external_sources = {},
    external_source_set = {},
    blocking_source = nil,
    on_descriptor = opts.on_descriptor,
    quiet_deadlock = opts.quiet_deadlock,
  }, Runtime)
end

function Runtime:bump_generation(_reason)
  self.generation = (self.generation or 0) + 1
  return self.generation
end

function Runtime:emit_descriptor(event)
  if self.on_descriptor then
    return self.on_descriptor(event)
  end
  return default_descriptor_handler(event)
end

function Runtime:register_external_source(source)
  if not source then return end
  if not self.external_source_set[source] then
    self.external_source_set[source] = true
    self.external_sources[#self.external_sources + 1] = source
  end
  if not self.blocking_source and source.wait then
    self.blocking_source = source
  end
end

function Runtime:set_blocking_source(source)
  self.blocking_source = source
  self:register_external_source(source)
end


function Runtime:settlement_cell(ref)
  local key = ref and ref.key or tostring(ref)
  local cell = self.settlements[key]
  if not cell then
    cell = SettlementCell.new(ref)
    self.settlements[key] = cell
  end
  return cell
end

function Runtime:publish_settlement(ref)
  local task = ref and ref.task or nil
  local attempt = ref and ref.attempt or (task and task.attempt) or nil
  if not attempt then
    error('cannot publish settlement without RootAttempt: ' .. tostring(ref and ref.key or ref), 2)
  end
  local cell = self:settlement_cell(ref)
  cell.published = true
  attempt.published_settlements[ref.key] = ref
  return cell
end

function Runtime:publish_frontier_settlements(attempt, frontier)
  local refs, seen = {}, {}
  for _, frame in ipairs(frontier or {}) do
    frame_collect_publishable_settlements(frame, refs, seen)
  end

  for _, ref in ipairs(refs) do
    -- Only refs belonging to this retained attempt are live disappointment candidates.
    if ref and ref.attempt == attempt then
      self:publish_settlement(ref)
    end
  end
end

function Runtime:publish_frontier_external_waits(attempt, frontier)
  local waits, seen = {}, {}
  for _, frame in ipairs(frontier or {}) do
    frame_collect_external_waits(frame, waits, seen)
  end

  for _, frame in ipairs(waits) do
    local resource = frame.resource
    if resource and resource.publish_wait then
      self:register_external_source(resource)
      local token = resource:publish_wait(self, attempt, frame)
      if token then
        attempt.external_waits[#attempt.external_waits + 1] = {
          resource = resource,
          token = token,
        }
      end
    end
  end
end

function Runtime:unpublish_attempt_external_waits(attempt)
  if not attempt then return end
  for _, wait in ipairs(attempt.external_waits or {}) do
    if wait.resource and wait.resource.unpublish_wait then
      wait.resource:unpublish_wait(self, wait.token)
    end
  end
  attempt.external_waits = {}
end

function Runtime:has_external_waits()
  for _, task in ipairs(self.waiting or {}) do
    local attempt = task.attempt
    if attempt and attempt.external_waits and #attempt.external_waits > 0 then
      return true
    end
  end
  return false
end

function Runtime:wait_external()
  local sources = self.external_sources or {}
  local now = nil
  local deadline = nil

  for _, source in ipairs(sources) do
    if source.next_deadline then
      local d = source:next_deadline(self)
      if d and (not deadline or d < deadline) then deadline = d end
    end
  end

  if deadline then
    if self.now then now = self:now() end
    -- If the runtime has no own clock, ask the blocking source or the first
    -- source with now().  A nil now means timeout remains nil unless the
    -- blocking source can interpret the absolute deadline itself.
    if now == nil then
      local bs = self.blocking_source
      if bs and bs.now then now = bs:now() end
    end
  end

  local timeout = nil
  if deadline and now then
    timeout = deadline - now
    if timeout < 0 then timeout = 0 end
  end

  local old_generation = self.generation
  local changed = false

  if self.blocking_source and self.blocking_source.wait then
    changed = self.blocking_source:wait(self, timeout, deadline) or changed
  elseif timeout ~= nil then
    -- No host sleep is assumed in the core.  Still poll below; fake clocks can
    -- advance in poll/wait, and already-expired deadlines use timeout 0.
  else
    return false
  end

  for _, source in ipairs(sources) do
    if source.poll then
      changed = source:poll(self) or changed
    end
  end

  if changed and self.generation == old_generation then
    self:bump_generation('external')
  end

  return changed or self.generation ~= old_generation
end


function Runtime:can_settle_cell(cell, state)
  if cell.state == state then return true end
  if cell.state ~= 'pending' then
    return nil, 'settlement ' .. tostring(cell.key) .. ' already settled as ' .. tostring(cell.state)
  end
  if state ~= 'selected' and state ~= 'lost' and state ~= 'withdrawn' then
    return nil, 'invalid settlement state: ' .. tostring(state)
  end
  return true
end

local function plan_settlement_update(updates, planned, cell, ref, state)
  local old = planned[cell.key]
  if old then
    if old.state ~= state then
      return nil, 'conflicting settlement update for ' .. tostring(cell.key)
    end
    return true
  end
  local update = { cell = cell, ref = ref, state = state }
  planned[cell.key] = update
  updates[#updates + 1] = update
  return true
end

function Runtime:prepare_world_settlement_updates(world)
  local updates = {}
  local planned = {}
  local selected = {}
  local selected_refs = {}
  local commit = world.evidence.commit

  for _, key in ipairs(commit.selected_settlement_order or {}) do
    local ref = commit.selected_settlements[key]
    selected[key] = true
    selected_refs[#selected_refs + 1] = ref
  end

  for _, ref in ipairs(selected_refs) do
    if ref.parent_key and not selected[ref.parent_key] then
      local parent_cell = self.settlements[ref.parent_key]
      if not (parent_cell and parent_cell.state == 'selected') then
        return nil, 'selected settlement has unselected parent: ' .. tostring(ref.key)
      end
    end

    local attempt = ref.attempt or (ref.task and ref.task.attempt)
    if attempt then
      local ok_attempt, attempt_reason = attempt:validate_live(self)
      if not ok_attempt then return nil, attempt_reason end
      if ref.task and ref.task.attempt ~= attempt then
        return nil, 'selected settlement belongs to stale task attempt'
      end
      if ref.attempt_id and attempt.id ~= ref.attempt_id then
        return nil, 'selected settlement attempt id mismatch'
      end
    end
  end

  for _, ref in ipairs(selected_refs) do
    local cell = self:settlement_cell(ref)
    local ok, reason = self:can_settle_cell(cell, 'selected')
    if not ok then return nil, reason end
    local ok_plan, plan_reason = plan_settlement_update(updates, planned, cell, ref, 'selected')
    if not ok_plan then return nil, plan_reason end
  end

  for _, resumption in ipairs(world.resumptions or {}) do
    local attempt = resumption.attempt
    local published = attempt and attempt.published_settlements or {}

    for key, ref in pairs(published) do
      if not selected[key] then
        local cell = self:settlement_cell(ref)
        if cell.published and cell.state == 'pending' then
          local state = 'lost'
          if ref.parent_key and not selected[ref.parent_key] then
            state = 'withdrawn'
          end

          local ok, reason = self:can_settle_cell(cell, state)
          if not ok then return nil, reason end
          local ok_plan, plan_reason = plan_settlement_update(updates, planned, cell, ref, state)
          if not ok_plan then return nil, plan_reason end
        end
      end
    end
  end

  return updates
end

function Runtime:apply_settlement_updates(updates)
  for _, update in ipairs(updates or {}) do
    local ok, reason = update.cell:settle(update.state)
    if not ok then return nil, reason end
  end
  return true
end

function Runtime:settle_selected_settlement(ref)
  local cell = self:settlement_cell(ref)
  return cell:settle('selected')
end

function Runtime:settle_world_settlements(world)
  local updates, reason = self:prepare_world_settlement_updates(world)
  if not updates then return nil, reason end
  return self:apply_settlement_updates(updates)
end

function Runtime:prepare_withdrawal_settlement_updates(attempt)
  local updates = {}
  local planned = {}
  local ok_attempt, reason = attempt:validate_live(self)
  if not ok_attempt then return nil, reason end

  for _, ref in pairs(attempt.published_settlements or {}) do
    local cell = self:settlement_cell(ref)
    if cell.published and cell.state == 'pending' then
      local ok, settle_reason = self:can_settle_cell(cell, 'withdrawn')
      if not ok then return nil, settle_reason end
      local ok_plan, plan_reason = plan_settlement_update(updates, planned, cell, ref, 'withdrawn')
      if not ok_plan then return nil, plan_reason end
    end
  end

  return updates
end

function Runtime:withdraw_attempt(attempt, reason)
  local updates, update_reason = self:prepare_withdrawal_settlement_updates(attempt)
  if not updates then return nil, update_reason end

  local ok, settlement_reason = self:apply_settlement_updates(updates)
  if not ok then return nil, settlement_reason end

  if attempt.state == 'parked' then attempt.state = 'withdrawn' end
  self:unpark(attempt.task, reason or 'withdrawn')
  self:bump_generation('withdraw')
  return true
end

function Runtime:spawn(fn, name)
  if in_search_phase() then error('cannot spawn during proof search expansion', 2) end
  self.next_task_id = self.next_task_id + 1
  local task = {
    id = self.next_task_id,
    name = name or ('task-' .. tostring(self.next_task_id)),
    co = coroutine.create(fn),
    values = pack(),
    frontier = nil,
    parked = false,
    attempt_id = 0,
    next_attempt_ordinal = 0,
    attempt = nil,
  }
  self.runnable[#self.runnable + 1] = task
  return task
end

function Runtime:park(task, op)
  task.next_attempt_ordinal = (task.next_attempt_ordinal or 0) + 1
  self:bump_generation('park')
  local attempt = RootAttempt.new(task, op, self.generation, task.next_attempt_ordinal)
  task.attempt = attempt
  task.attempt_id = attempt.id
  local root_label = attempt.label
  task.op = op
  task.root_label = root_label
  task.frontier = run_in_phase('search', function()
    return expand_expr(op, empty_evidence(), ExpansionContext.root(root_label, task, nil, attempt))
  end)
  task.parked = true
  if not self.waiting_set[task] then
    self.waiting[#self.waiting + 1] = task
    self.waiting_set[task] = true
  end
  self:publish_frontier_settlements(attempt, task.frontier)
  self:publish_frontier_external_waits(attempt, task.frontier)
end

function Runtime:unpark(task, reason)
  if not self.waiting_set[task] then return end
  self:unpublish_attempt_external_waits(task.attempt)
  self:bump_generation('unpark')
  self.waiting_set[task] = nil
  task.parked = false
  task.frontier = nil
  if task.attempt and task.attempt.state == 'parked' then
    task.attempt.state = (reason == 'commit') and 'committed' or 'withdrawn'
  end
  for i = #self.waiting, 1, -1 do
    if self.waiting[i] == task then table.remove(self.waiting, i); return end
  end
end

function Runtime:resume_task(task)
  local ok, yielded = with_current_task(task, function()
    return coroutine.resume(task.co, unpack_pack(task.values))
  end)
  task.values = pack()

  if not ok then error(task.name .. ': ' .. tostring(yielded)) end
  if coroutine.status(task.co) == 'dead' then return end

  if type(yielded) ~= 'table' or not yielded.tag then
    error(task.name .. ': yielded non-operation')
  end

  self:park(task, yielded)
end

function Runtime:search_closed_world(proof, budget)
  local result = ProofSearch.new(self, proof, budget):run()
  if result.status == 'found' then return result.world, result end
  return nil, result
end


function Runtime:initial_proofs_for_task(task, forced_decisions)
  local root_label = task.root_label or ('task-' .. tostring(task.id) .. '/attempt-' .. tostring(task.attempt_id or 0))
  local frames
  if forced_decisions then
    frames = expand_expr(task.op, empty_evidence(), ExpansionContext.root(root_label, task, forced_decisions))
  else
    frames = task.frontier or {}
  end

  local proofs = {}
  for _, frame in ipairs(frames) do
    local used = { [task] = true }
    local proof = PartialProof.new(expand_top_frame(task, frame), used, {})
    if proof:fragments_compatible() then proofs[#proofs + 1] = proof end
  end
  return proofs
end

function Runtime:search_task(task, forced_decisions, budget)
  local proofs = self:initial_proofs_for_task(task, forced_decisions)
  local saw_budget = nil
  for _, proof in ipairs(proofs) do
    local result = ProofSearch.new(self, proof, budget):run()
    if result.status == 'found' then return result end
    if result.status == 'budget' then saw_budget = result end
  end
  return saw_budget or { status = 'absent', generation = self.generation }
end

local function forced_decisions_for_obligation(obligation)
  local forced = {}

  for i = 1, #(obligation.prefix or {}) do
    local d = obligation.prefix[i]
    local existing = forced[d.site]
    if existing ~= nil and existing ~= d.branch then
      return nil, 'conflicting preference prefix'
    end
    forced[d.site] = d.branch
  end

  local force = obligation.force or 'primary'
  local existing = forced[obligation.site]
  if existing ~= nil and existing ~= force then
    return nil, 'obligation conflicts with its prefix'
  end

  forced[obligation.site] = force
  return forced
end

function Runtime:prove_obligation(obligation, judgement)
  judgement = require_judgement('Runtime:prove_obligation', judgement)

  if not obligation.task then
    return { status = 'discharged', reason = 'no task for obligation', generation = judgement.generation }
  end

  local forced, reason = forced_decisions_for_obligation(obligation)
  if not forced then
    return { status = 'discharged', reason = reason, generation = judgement.generation }
  end

  local result = self:search_committable_task(obligation.task, forced, judgement)
  if result.status == 'found' then
    return {
      status = 'dominated',
      world = result.world,
      obligation = obligation,
      generation = judgement.generation,
    }
  elseif result.status == 'budget' then
    return {
      status = 'budget',
      obligation = obligation,
      reason = result.reason,
      generation = judgement.generation,
    }
  elseif result.status == 'absent' then
    return {
      status = 'discharged',
      obligation = obligation,
      reason = result.reason,
      generation = judgement.generation,
    }
  end

  return {
    status = result.status or 'unknown',
    obligation = obligation,
    reason = result.reason,
    generation = judgement.generation,
  }
end

function Runtime:prove_committable(world, judgement)
  judgement = require_judgement('Runtime:prove_committable', judgement)

  local obligations = world:preference_obligations()
  for i = 1, #obligations do
    local result = self:prove_obligation(obligations[i], judgement)
    if result.status == 'dominated' then
      return { status = 'dominated', world = result.world, obligation = obligations[i] }
    elseif result.status == 'budget' then
      return { status = 'budget', obligation = obligations[i], reason = result.reason }
    elseif result.status ~= 'discharged' then
      return { status = result.status or 'unknown', obligation = obligations[i], reason = result.reason }
    end
  end
  world.preference_obligations_discharged = true
  return { status = 'committable', world = world }
end

function Runtime:_search_committable_task_uncached(task, forced_decisions, judgement)
  local saw_dominated = false

  local function accept_world(world)
    local proof = self:prove_committable(world, judgement)
    if proof.status == 'committable' then
      return { status = 'accept', world = world }
    elseif proof.status == 'dominated' then
      saw_dominated = true
      return { status = 'reject', reason = 'dominated by preferred committable world', dominated_by = proof.world }
    elseif proof.status == 'budget' then
      return { status = 'budget', reason = proof.reason or 'preference obligation proof budget' }
    else
      return { status = 'reject', reason = proof.status or 'not committable' }
    end
  end

  local proofs = self:initial_proofs_for_task(task, forced_decisions)
  for _, proof in ipairs(proofs) do
    local result = ProofSearch.new(self, proof, judgement, accept_world):run()
    if result.status == 'found' then return result end
    if result.status == 'budget' then return result end
  end

  return {
    status = 'absent',
    generation = judgement.generation,
    used = judgement.fuel.used,
    reason = saw_dominated and 'all candidates absent or dominated' or 'absent',
  }
end

function Runtime:search_committable_task(task, forced_decisions, judgement)
  judgement = require_judgement('Runtime:search_committable_task', judgement)
  if forced_decisions ~= nil and type(forced_decisions) ~= 'table' then
    error('Runtime:search_committable_task forced_decisions must be a table or nil', 2)
  end

  if self.generation ~= judgement.generation then
    return {
      status = 'budget',
      generation = judgement.generation,
      used = judgement.fuel.used,
      reason = 'generation changed',
    }
  end

  local key = committable_search_key(task, forced_decisions, judgement.generation)
  if judgement.stack[key] then
    return {
      status = 'budget',
      generation = judgement.generation,
      used = judgement.fuel.used,
      reason = 'cyclic committability judgement',
    }
  end

  if judgement.memo[key] then return judgement.memo[key] end

  judgement.stack[key] = true
  local result = self:_search_committable_task_uncached(task, forced_decisions, judgement)
  judgement.stack[key] = nil

  judgement.memo[key] = result
  return result
end

function Runtime:try_commit_one(search_budget)
  local judgement = JudgementContext.new(self, search_budget)
  for _, task in ipairs(self.waiting) do
    if task.parked then
      local result = self:search_committable_task(task, nil, judgement)
      if result.status == 'found' then
        result.world:commit(self)
        return 'committed'
      elseif result.status == 'budget' then
        return 'budget', result
      end
    end
  end

  return 'blocked'
end

function Runtime:step(opts)
  opts = opts or {}
  local resume_budget = opts.resume_budget or 1
  local commit_budget = opts.commit_budget or 1

  local resumed = 0
  while resumed < resume_budget and #self.runnable > 0 do
    local task = table.remove(self.runnable, 1)
    self:resume_task(task)
    resumed = resumed + 1
  end
  if resumed > 0 then return { status = 'resumed', count = resumed } end

  if #self.waiting == 0 then return { status = 'idle' } end

  local commits = 0
  while commits < commit_budget do
    local status, result = self:try_commit_one(opts.search_budget)
    if status == 'committed' then
      commits = commits + 1
    elseif status == 'budget' then
      return { status = 'budget', result = result }
    else
      break
    end
  end

  if commits > 0 then return { status = 'committed', count = commits } end

  if self:has_external_waits() then
    return { status = 'waiting_external' }
  end

  return { status = 'deadlock' }
end

function Runtime:run(opts)
  while true do
    local step = self:step(opts)
    if step.status == 'idle' then
      return
    elseif step.status == 'budget' then
      error('budget: proof search incomplete')
    elseif step.status == 'waiting_external' then
      local changed = self:wait_external()
      if not changed then
        if not self.quiet_deadlock then
          io.stderr:write('deadlock: external waits made no progress\n')
        end
        error('deadlock')
      end
    elseif step.status == 'deadlock' then
      if not self.quiet_deadlock then
        io.stderr:write('deadlock: no closed proof can be constructed\n')
        for _, task in ipairs(self.waiting) do
          io.stderr:write('  waiting: ' .. tostring(task.name) .. '\n')
        end
      end
      error('deadlock')
    end
  end
end

return { Runtime = Runtime }
