local Machine = require('et.machine')

local Kernel = require('et.kernel')
local FrontierLayer = Machine.Frontier

local Status = Kernel.Status
local Phase = Kernel.Phase
local View = FrontierLayer.View
local Frontier = FrontierLayer.Frontier
local ProofSearch = Machine.ProofNet
local CommitCertificate = Machine.Commit.Certificate
local Consequence = FrontierLayer.Consequence
local Util = Kernel.Util
local Obligation = FrontierLayer.Obligation

local Runtime = {}
Runtime.__index = Runtime

local next_runtime_id = 0

local function new_scheduler()
  return { by_resource = {}, stale_seen = {}, stale_order = {}, dirty_seen = {}, dirty_order = {} }
end

function Runtime.new(opts)
  opts = opts or {}
  next_runtime_id = next_runtime_id + 1
  local id = 'runtime-' .. tostring(next_runtime_id)
  return setmetatable({
    id = id,
    runnable = {}, waiting = {}, tasks = {},
    quiet_deadlock = opts.quiet_deadlock or false,
    on_consequence = opts.on_consequence,
    obligations = opts.obligation_store or Obligation.Store.new(id .. '/obligations'),
    host = opts.host or {},
    stats = { refreshes = 0, commits = 0, fixpoint_iterations = 0, dirty_marks = 0, dependency_marks = 0, stale_frontier_marks = 0, stale_frontier_refreshes = 0 },
    external_waits = {}, dirty_resources = {}, scheduler = new_scheduler(),
    next_task_id = 0, next_attempt_id = 0,
  }, Runtime)
end

local function push(xs, x) xs[#xs + 1] = x end
local function remove_at(xs, idx) local x = xs[idx]; table.remove(xs, idx); return x end

local function publish_frontier_obligations(attempt, frontier)
  attempt.current_obligations = {}
  attempt.all_obligations = attempt.all_obligations or {}
  attempt.all_obligations_seen = attempt.all_obligations_seen or {}
  attempt.published_obligations = attempt.current_obligations
  local seen_current = {}
  for i = 1, #(frontier and frontier.obligation_publications or {}) do
    local ref = frontier.obligation_publications[i]
    if ref and ref.id and not seen_current[ref.id] then
      seen_current[ref.id] = true
      local p = attempt.obligation_store:publish(ref)
      if not Status.is_found(p) then return p end
      attempt.current_obligations[#attempt.current_obligations + 1] = ref
      if not attempt.all_obligations_seen[ref.id] then
        attempt.all_obligations_seen[ref.id] = true
        attempt.all_obligations[#attempt.all_obligations + 1] = ref
      end
    end
  end
  return Status.found(attempt.current_obligations)
end

local function host_watch(runtime, wait, token)
  Phase.require(token, 'external')
  local host = runtime.host or {}
  if type(host.watch) == 'function' then
    local ok, r = pcall(function() return host:watch(wait, runtime, token) end)
    if not ok then return Status.fatal(r) end
    return r or Status.found(true)
  end
  return Status.found(true)
end

local function host_unwatch(runtime, wait, token)
  Phase.require(token, 'external')
  local host = runtime.host or {}
  if type(host.unwatch) == 'function' then
    local ok, r = pcall(function() return host:unwatch(wait, runtime, token) end)
    if not ok then return Status.fatal(r) end
    return r or Status.found(true)
  end
  return Status.found(true)
end

local function unpublish_external_waits(runtime, attempt)
  if not attempt then return Status.found(true) end
  local waits = attempt.current_external_waits or {}
  if #waits == 0 then return Status.found(true) end
  return Phase.with('external', function(token)
    for i = 1, #waits do
      local wait = waits[i]
      local r = host_unwatch(runtime, wait, token)
      if not Status.is_found(r) then return r end
      runtime.external_waits[wait.id or tostring(wait)] = nil
    end
    attempt.current_external_waits = {}
    return Status.found(true)
  end)
end

local function publish_frontier_external_waits(runtime, attempt, frontier)
  local un = unpublish_external_waits(runtime, attempt)
  if not Status.is_found(un) then return un end
  attempt.current_external_waits = {}
  return Phase.with('external', function(token)
    for i = 1, #(frontier and frontier.external_waits or {}) do
      local wait = frontier.external_waits[i]
      wait.id = wait.id or (attempt.id .. '/external-wait-' .. tostring(i))
      wait.attempt = attempt
      local r = host_watch(runtime, wait, token)
      if not Status.is_found(r) then return r end
      attempt.current_external_waits[#attempt.current_external_waits + 1] = wait
      runtime.external_waits[wait.id] = wait
    end
    return Status.found(attempt.current_external_waits)
  end)
end

function Runtime:unregister_frontier(task)
  local deps = task and task.dependency_resources or {}
  for i = 1, #deps do
    local set = self.scheduler.by_resource[deps[i]]
    if set then set[task] = nil end
  end
  if task then
    task.dependency_resources = {}
    self.scheduler.stale_seen[task] = nil
    task.frontier_stale = false
  end
end

function Runtime:register_frontier(task)
  if not (task and task.frontier and task.frontier.dependencies) then return Status.found(true) end
  self:unregister_frontier(task)
  task.dependency_resources = {}
  local deps = task.frontier.dependencies
  for i = 1, #(deps.order or {}) do
    local resource = deps.order[i]
    task.dependency_resources[#task.dependency_resources + 1] = resource
    local set = self.scheduler.by_resource[resource]
    if not set then set = {}; self.scheduler.by_resource[resource] = set end
    set[task] = true
  end
  return Status.found(true)
end

function Runtime:mark_task_stale(task, reason)
  if not (task and task.state == 'waiting' and task.frontier) then return end
  if not self.scheduler.stale_seen[task] then
    self.scheduler.stale_seen[task] = true
    self.scheduler.stale_order[#self.scheduler.stale_order + 1] = task
    self.stats.stale_frontier_marks = self.stats.stale_frontier_marks + 1
  end
  task.frontier_stale = true
  task.stale_reason = reason or task.stale_reason
end

function Runtime:mark_dirty(resources, reason)
  local seen = {}; resources = resources or {}
  for i = 1, #resources do
    local resource = resources[i]
    if resource and not seen[resource] then
      seen[resource] = true
      self.stats.dirty_marks = self.stats.dirty_marks + 1
      if not self.scheduler.dirty_seen[resource] then
        self.scheduler.dirty_seen[resource] = true
        self.scheduler.dirty_order[#self.scheduler.dirty_order + 1] = resource
      end
      for task, _ in pairs(self.scheduler.by_resource[resource] or {}) do
        self.stats.dependency_marks = self.stats.dependency_marks + 1
        self:mark_task_stale(task, reason or 'dirty resource')
      end
    end
  end
  self.dirty_resources = Util.copy_list(resources)
  return Status.found(true)
end

function Runtime:audit_stale_frontiers()
  local count = 0
  for i = 1, #self.waiting do
    local task = self.waiting[i]
    if task.frontier and not task.frontier:is_fresh(task.view) then
      self:mark_task_stale(task, 'frontier freshness audit')
      count = count + 1
    end
  end
  return count
end

function Runtime:spawn(fn, label)
  if type(fn) ~= 'function' then error('Runtime.spawn: expected function', 2) end
  local phase = Phase.current()
  if phase ~= 'idle' and phase ~= 'post' then error('Runtime.spawn is not permitted during ' .. tostring(phase) .. ' phase', 2) end
  self.next_task_id = self.next_task_id + 1
  local task = { id = self.next_task_id, label = label or ('task-' .. tostring(self.next_task_id)), co = coroutine.create(fn), state = 'runnable', resume_values = Util.pack(), dependency_resources = {} }
  push(self.tasks, task); push(self.runnable, task); return task
end

function Runtime:perform(op)
  local phase = Phase.current()
  if phase ~= 'idle' and phase ~= 'post' then error('Runtime.perform is not permitted during ' .. tostring(phase) .. ' phase', 2) end
  local _co, is_main = coroutine.running()
  if is_main then error('Runtime.perform may only be called inside a runtime fibre', 2) end
  local record = coroutine.yield({ tag = 'perform', op = op })
  if type(record) ~= 'table' or record.tag ~= 'committed' then error('Runtime.perform resumed with invalid commit record', 2) end
  return Phase.with('post', function(_token)
    local current = record.values or Util.pack()
    for i = 1, #(record.post_programs or {}) do current = Util.pack(record.post_programs[i](Util.unpack(current))) end
    return Util.unpack(current)
  end)
end

function Runtime:park(task, op)
  self.next_attempt_id = self.next_attempt_id + 1
  local attempt = { id = self.id .. '/attempt-' .. tostring(self.next_attempt_id), task = task, current_obligations = {}, all_obligations = {}, all_obligations_seen = {}, expansion_memo = {}, obligation_store = self.obligations }
  local view = View.open(task.label .. '/view-' .. tostring(self.next_attempt_id))
  local frontier_status = Phase.with('search', function(token) return Frontier.expand(op, attempt, view, token) end)
  if not Status.is_found(frontier_status) then return frontier_status end
  local published = publish_frontier_obligations(attempt, frontier_status.value); if not Status.is_found(published) then return published end
  local external = publish_frontier_external_waits(self, attempt, frontier_status.value); if not Status.is_found(external) then return external end
  task.state = 'waiting'; task.op = op; task.attempt = attempt; task.view = view; task.frontier = frontier_status.value; task.frontier_stale = false
  push(self.waiting, task)
  self:register_frontier(task)
  return Status.found(true)
end

function Runtime:refresh(task)
  local view = View.open(task.label .. '/refresh-' .. tostring(self.stats.refreshes + 1))
  local refreshed = Phase.with('search', function(token) return task.frontier:refresh(view, token) end)
  if not Status.is_found(refreshed) then return refreshed end
  local published = publish_frontier_obligations(task.attempt, refreshed.value); if not Status.is_found(published) then return published end
  local external = publish_frontier_external_waits(self, task.attempt, refreshed.value); if not Status.is_found(external) then return external end
  self:unregister_frontier(task)
  task.view = view; task.frontier = refreshed.value; task.frontier_stale = false; task.stale_reason = nil
  self:register_frontier(task)
  self.stats.refreshes = self.stats.refreshes + 1
  self.stats.stale_frontier_refreshes = self.stats.stale_frontier_refreshes + 1
  return Status.found(true)
end

function Runtime:refresh_stale_waiting(resources)
  if resources and #resources > 0 then
    local marked = self:mark_dirty(resources, 'stale status from search/certification')
    if not Status.is_found(marked) then return marked end
  end
  self:audit_stale_frontiers()
  local refreshed = 0
  while #self.scheduler.stale_order > 0 do
    local task = remove_at(self.scheduler.stale_order, 1)
    if self.scheduler.stale_seen[task] then
      self.scheduler.stale_seen[task] = nil
      if task.state == 'waiting' and task.frontier then
        if task.frontier:is_fresh(task.view) then
          task.frontier_stale = false; task.stale_reason = nil
        else
          local r = self:refresh(task)
          if not Status.is_found(r) then return r end
          refreshed = refreshed + 1
        end
      end
    end
  end
  self.scheduler.dirty_seen = {}; self.scheduler.dirty_order = {}
  return Status.found({ refreshed = refreshed, resources = resources or {} })
end

function Runtime:run_one_runnable()
  local task = remove_at(self.runnable, 1)
  if not task then return false end
  if task.state == 'done' then return true end
  task.state = 'running'
  local values = task.resume_values or Util.pack(); task.resume_values = Util.pack()
  local ok, yielded = coroutine.resume(task.co, Util.unpack(values))
  if not ok then task.state = 'failed'; task.error = yielded; self.stats.failures = (self.stats.failures or 0) + 1; return true end
  if coroutine.status(task.co) == 'dead' then task.state = 'done'; task.result = yielded; return true end
  if type(yielded) ~= 'table' or yielded.tag ~= 'perform' then error('runtime fibre yielded unsupported request', 2) end
  local parked = self:park(task, yielded.op)
  if not Status.is_found(parked) then task.state = 'failed'; task.error = parked; self.pending_status = parked; self.stats.failures = (self.stats.failures or 0) + 1; return true end
  return true
end

local function waiting_inputs(waiting)
  local inputs = {}
  for i = 1, #waiting do inputs[#inputs + 1] = { task = waiting[i], frontier = waiting[i].frontier, view = waiting[i].view } end
  return inputs
end

local function waiting_index_by_task(waiting, task)
  for i = 1, #waiting do if waiting[i] == task then return i end end
  return nil
end

function Runtime:resume_committed_roots(cert)
  local to_resume = {}
  for i = 1, #cert.resumptions do
    local attempt = cert.resumptions[i].attempt
    local task = attempt and attempt.task
    if task then to_resume[#to_resume + 1] = { task = task, record = { tag = 'committed', values = cert.resumptions[i].values, post_programs = Util.copy_list(cert.resumptions[i].post_programs) } } end
  end
  local indices = {}
  for i = 1, #to_resume do local idx = waiting_index_by_task(self.waiting, to_resume[i].task); if idx then indices[#indices + 1] = idx end end
  table.sort(indices, function(a,b) return a>b end)
  for i = 1, #indices do remove_at(self.waiting, indices[i]) end
  for i = 1, #to_resume do
    local task = to_resume[i].task
    self:unregister_frontier(task)
    unpublish_external_waits(self, task.attempt)
    task.frontier = nil; task.view = nil; task.attempt = nil; task.state = 'runnable'; task.resume_values = Util.pack(to_resume[i].record)
    push(self.runnable, task)
  end
end

function Runtime:withdraw(task)
  if type(task) ~= 'table' then return Status.fatal('Runtime.withdraw requires task') end
  if task.state ~= 'waiting' then return Status.fatal('Runtime.withdraw requires waiting task') end
  local attempt = task.attempt
  self:unregister_frontier(task)
  local unext = unpublish_external_waits(self, attempt); if not Status.is_found(unext) then return unext end
  for i = 1, #(attempt and attempt.all_obligations or {}) do
    local w = attempt.obligation_store:withdraw(attempt.all_obligations[i])
    if not Status.is_found(w) and w.tag ~= 'conflict' then return w end
  end
  local idx = waiting_index_by_task(self.waiting, task); if idx then remove_at(self.waiting, idx) end
  task.state = 'withdrawn'; task.frontier = nil; task.view = nil; task.attempt = nil
  return Status.found(true)
end

function Runtime:try_one_commit()
  local refreshed = self:refresh_stale_waiting(); if not Status.is_found(refreshed) then return refreshed end
  local rejected = {}
  while true do
    self.stats.fixpoint_iterations = self.stats.fixpoint_iterations + 1
    local candidate = Phase.with('search', function(token) return ProofSearch.find(waiting_inputs(self.waiting), nil, token, { rejected = rejected }) end)
    if candidate.tag == 'pending' then return candidate end
    if candidate.tag == 'stale' then
      local r = self:refresh_stale_waiting(candidate.resources); if not Status.is_found(r) then return r end
      if r.value.refreshed == 0 then return Status.fatal('stale search result did not correspond to any stale frontier', candidate) end
      return Status.budget('stale frontiers refreshed; retry search')
    end
    if not Status.is_found(candidate) then return candidate end
    local cert = CommitCertificate.try_build(candidate.value)
    if cert.tag == 'stale' then
      local r = self:refresh_stale_waiting(cert.resources); if not Status.is_found(r) then return r end
      if r.value.refreshed == 0 then return Status.fatal('stale certificate did not correspond to any stale frontier', cert) end
      return Status.budget('stale certificate; retry search')
    end
    if Status.is_reject_candidate(cert) then
      local key = cert.detail and cert.detail.candidate_key or candidate.value.key
      rejected[key] = true
    elseif not Status.is_found(cert) then
      return cert
    else
      local applied = cert.value:apply(); if not Status.is_found(applied) then return applied end
      if cert.value.state ~= 'applied' then return Status.fatal('commit certificate did not reach applied state') end
      self.stats.commits = self.stats.commits + 1
      local marked = self:mark_dirty(cert.value.dirty or {}, 'commit dirty set'); if not Status.is_found(marked) then return marked end
      local interpreted = Phase.with('consequence', function(token) return Consequence.interpret(cert.value.consequences, self, token) end)
      if not Status.is_found(interpreted) then return interpreted end
      if self.on_consequence then
        local ok, err = pcall(function() Phase.with('consequence', function(_token) self.on_consequence(Consequence.copy(interpreted.value)) end) end)
        if not ok then self.consequence_errors = self.consequence_errors or {}; self.consequence_errors[#self.consequence_errors + 1] = err end
      end
      self:resume_committed_roots(cert.value)
      return Status.found(true)
    end
  end
end

function Runtime:at_fixpoint_status(status)
  local r = self:refresh_stale_waiting(); if not Status.is_found(r) then return r end
  if r.value.refreshed > 0 then return Status.budget('stale frontier refreshed before quiescence') end
  return status
end

function Runtime:run()
  while true do
    while #self.runnable > 0 do self:run_one_runnable() end
    if self.pending_status then return self.pending_status end
    local all_done = true
    for i = 1, #self.tasks do if self.tasks[i].state ~= 'done' and self.tasks[i].state ~= 'failed' then all_done = false; break end end
    if all_done then return Status.found(true) end
    local committed = self:try_one_commit()
    if Status.is_found(committed) then
    elseif committed.tag == 'budget' then
    elseif committed.tag == 'pending' then
      return committed
    elseif committed.tag == 'absent' or committed.tag == 'conflict' or committed.tag == 'reject_candidate' then
      local fixed = self:at_fixpoint_status(committed)
      if fixed.tag == 'budget' then
      elseif self.quiet_deadlock then return fixed
      else error('deadlock: ' .. tostring(fixed.reason), 2) end
    else
      return committed
    end
  end
end

return Runtime
