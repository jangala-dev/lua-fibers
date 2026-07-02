local Op = require('fibers.atoms.op')
local Resources = require('fibers.kernel.resources')
local Proof = require('fibers.kernel.proof')
local AbsenceCert = Proof.AbsenceCert
local Capture = Proof.Capture

local unpack_ = Op._unpack
local pack_ = Op._pack

local Net = {}

-- Optional structural counters.  Disabled by default so normal proof search
-- does not retain accounting tables.  Set FIBERS_COUNTERS=1, or call
-- Net.enable_counters(true), to collect representation/work counts.
local counters_enabled = os.getenv('FIBERS_COUNTERS') == '1'
local counters = {}

local function count(kind, n)
  if not counters_enabled then return end
  counters[kind] = (counters[kind] or 0) + (n or 1)
end

function Net.enable_counters(enabled)
  counters_enabled = enabled ~= false
  counters = {}
end

function Net.reset_counters() counters = {} end

function Net.counters()
  local out = {}
  for k, v in pairs(counters) do out[k] = v end
  return out
end

-- Search outcomes ---------------------------------------------------------

local Outcome = {}

local function append_all(dst, src)
  for i = 1, #(src or {}) do dst[#dst + 1] = src[i] end
end

function Outcome.hit(world) return { tag = 'hit', world = world } end
function Outcome.miss(cert, waits) return { tag = 'miss', cert = cert or AbsenceCert.new(), waits = waits or {} } end
function Outcome.unknown(waits, reason) return { tag = 'unknown', waits = waits or {}, reason = reason } end

function Outcome.merge(a, b)
  if not a then return b end
  if not b then return a end
  local waits = a.waits
  if not waits then waits = {}; a.waits = waits end
  append_all(waits, b.waits)
  if a.tag == 'unknown' or b.tag == 'unknown' then
    a.tag = 'unknown'
    a.reason = a.reason or b.reason
    return a
  end
  if b.cert and (not b.cert.is_empty or not b.cert:is_empty()) then
    if not (a.cert and a.cert.extend) then a.cert = AbsenceCert.new(a.cert) end
    a.cert:extend(b.cert)
  elseif a.cert and not a.cert.extend then
    a.cert = AbsenceCert.new(a.cert)
  end
  a.tag = 'miss'
  return a
end

Net.Outcome = Outcome


-- Speculative rollback trail ---------------------------------------------

local Trail = {}
Trail.__index = Trail

function Trail.new()
  if counters_enabled then count('trail.new') end
  return setmetatable({ entries = {} }, Trail)
end

function Trail:mark()
  return #self.entries
end

function Trail:set(t, k, v)
  local old = t[k]
  if counters_enabled then count('trail.entry') end
  self.entries[#self.entries + 1] = function() t[k] = old end
  t[k] = v
end

function Trail:append(t, v)
  if counters_enabled then count('trail.append') end
  local n = #t
  self.entries[#self.entries + 1] = function() t[n + 1] = nil end
  t[n + 1] = v
end

function Trail:remove_at(t, idx)
  if counters_enabled then count('trail.remove_at') end
  local n = #t
  local old = t[idx]
  self.entries[#self.entries + 1] = function()
    for i = n, idx + 1, -1 do t[i] = t[i - 1] end
    t[idx] = old
    t[n + 1] = nil
  end
  table.remove(t, idx)
  return old
end

function Trail:save_table(t)
  if counters_enabled then count('trail.save_table') end
  local before = {}
  for k, v in pairs(t) do before[k] = v end
  self.entries[#self.entries + 1] = function()
    for k, _ in pairs(t) do t[k] = nil end
    for k, v in pairs(before) do t[k] = v end
  end
end

function Trail:rollback(mark)
  for i = #self.entries, mark + 1, -1 do self.entries[i]() end
  for i = #self.entries, mark + 1, -1 do self.entries[i] = nil end
end

Net.Trail = Trail


-- Proof result and task helpers ------------------------------------------

local function copy_pack(p)
  if counters_enabled then count('alloc.pack') end
  local q = { _fibers_pack = true, n = p and (p.n or #p) or 0 }
  if p and p._fibers_pack then q._fibers_pack = true end
  for i = 1, q.n do q[i] = p[i] end
  return q
end

local function op_values(op)
  return op.values or op.vals or pack_()
end

local function op_inner(op) return op.inner or op.p end
local function op_primary(op) return op.primary or op.p end
local function op_fallback(op) return op.fallback or op.q end

local function new_result(pack, lanes)
  if counters_enabled then count('alloc.result') end
  return { pack = copy_pack(pack), wraps = {}, lanes = lanes }
end


local function stack_push(stack, frame)
  if counters_enabled then count('stack.push') end
  return { frame = frame, parent = stack, depth = (stack and stack.depth or 0) + 1 }
end

local function stack_pop(stack)
  if not stack then return nil, nil end
  if counters_enabled then count('stack.pop') end
  return stack.frame, stack.parent
end

local function copy_stack(stack)
  -- Continuation stacks are persistent linked frames.  Copying a task now shares
  -- the immutable parent chain instead of cloning an array of frames.
  if counters_enabled then count('stack.share') end
  return stack
end

local function copy_task(t)
  if counters_enabled then count('copy.task') end
  return {
    root_id = t.root_id,
    op = t.op,
    stack = copy_stack(t.stack),
    env = Resources.copy_env(t.env),
    attempt = t.attempt,
  }
end

local function copy_premise(p)
  if counters_enabled then count('copy.premise') end
  local groups = {}
  for i = 1, #(p.groups or {}) do groups[i] = p.groups[i] end
  local group_lanes = nil
  if p.group_lanes then
    group_lanes = {}
    for k, v in pairs(p.group_lanes) do group_lanes[k] = v end
  end
  return {
    id = p.id,
    root_id = p.root_id,
    resource = p.resource,
    kind = p.kind,
    payload = p.payload,
    request = p.request,
    wait = p.wait,
    task = copy_task(p.task),
    groups = groups,
    group_lanes = group_lanes,
  }
end


-- Mutable proof-search attempt -------------------------------------------

local collect_groups_from_stack

local Attempt = {}
Attempt.__index = Attempt

function Attempt.new(rt, pending, start_id, solver)
  local self = setmetatable({
    rt = rt,
    pending = pending,
    pending_ids = solver and solver.pending_ids or nil,
    observer = solver and solver.observer or nil,
    capture = solver and solver.capture or Capture.none(),
    selected = { [start_id] = true },
    tasks = {},
    premises = {},
    premise_index = {},
    done = {},
    groups = {},
    next_group = 0,
    next_premise = 0,
    next_contribution = 0,
    conflict = false,
    conflict_reason = nil,
    frontier_waits = {},
    outcome = nil,
    trail = Trail.new(),
    solver = solver,
  }, Attempt)
  self:push_task({ root_id = start_id, op = pending[start_id].op, stack = nil, env = Resources.new_env(nil, self.capture), attempt = pending[start_id].attempt })
  return self
end

function Attempt:mark() return self.trail:mark() end
function Attempt:rollback(mark) self.trail:rollback(mark) end
function Attempt:save(t) self.trail:save_table(t) end
function Attempt:set_field(t, k, v) self.trail:set(t, k, v) end
function Attempt:append(t, v) self.trail:append(t, v) end
function Attempt:remove_at(t, idx) return self.trail:remove_at(t, idx) end
function Attempt:charge(kind) if self.solver and self.solver.charge then self.solver:charge(kind) end end

function Attempt:set_conflict(reason)
  if not self.conflict then self:set_field(self, 'conflict', true) end
  if reason ~= nil and self.conflict_reason == nil then self:set_field(self, 'conflict_reason', reason) end
end

function Attempt:set_outcome(outcome)
  self:set_field(self, 'outcome', outcome)
  self:set_conflict(outcome and outcome.reason or (outcome and outcome.tag) or 'blocked')
end

function Attempt:set_miss(cert, waits) self:set_outcome(Outcome.miss(cert, waits)) end
function Attempt:set_unknown(waits, reason) self:set_outcome(Outcome.unknown(waits, reason)) end

local function premise_bucket_less(a, b)
  local ar = a.resource
  local br = b.resource
  local ak = (ar and (ar._fibers_id or ar.name)) or tostring(ar)
  local bk = (br and (br._fibers_id or br.name)) or tostring(br)
  if tostring(ak) == tostring(bk) then
    local an = a.kind and a.kind.name or ''
    local bn = b.kind and b.kind.name or ''
    return an < bn
  end
  return tostring(ak) < tostring(bk)
end

local function sort_premise_buckets(buckets)
  table.sort(buckets, premise_bucket_less)
  return buckets
end

function Attempt:rebuild_premise_index()
  -- Compatibility fallback for tests/debugging.  Normal proof search treats
  -- premise buckets as a lazy derived view so pushing or solving a premise does
  -- not rebuild and sort the whole index immediately.
  local idx = {}
  local buckets = {}
  for i = 1, #self.premises do
    local p = self.premises[i]
    local bucket = idx[p.resource]
    if not bucket then
      bucket = { resource = p.resource, kind = p.kind, premises = {} }
      idx[p.resource] = bucket
      buckets[#buckets + 1] = bucket
    end
    bucket.premises[#bucket.premises + 1] = p
  end
  sort_premise_buckets(buckets)
  self:set_field(self, 'premise_index', idx)
  self:set_field(self, 'premise_buckets', buckets)
end

function Attempt:push_task(task)
  if counters_enabled then count('task.push') end
  self:append(self.tasks, task)
end

function Attempt:remove_task(idx)
  if counters_enabled then count('task.remove') end
  local original = self:remove_at(self.tasks, idx)
  return copy_task(original)
end

function Attempt:push_premise(premise)
  if counters_enabled then count('premise.push') end
  self:set_field(self, 'next_premise', self.next_premise + 1)
  premise.id = self.next_premise
  premise.root_id = premise.task and premise.task.root_id or premise.root_id
  if not premise.groups then
    premise.groups, premise.group_lanes = collect_groups_from_stack(premise.task and premise.task.stack or nil)
  elseif not premise.group_lanes then
    local _groups, group_lanes = collect_groups_from_stack(premise.task and premise.task.stack or nil)
    premise.group_lanes = group_lanes
  end
  self:append(self.premises, premise)
  -- Premise buckets are a derived view.  Do not trail-maintain them on the
  -- hot push path; clear the cache and rebuild only when a resolver or absence
  -- pass asks for grouped premises.
  self.premise_index = nil
  self.premise_buckets = nil
end

function Attempt:remove_premises(ids)
  if counters_enabled then count('premise.remove_batch') end
  local wanted = {}
  for i = 1, #(ids or {}) do wanted[ids[i]] = true end
  local removed = {}
  local any = false
  for i = #self.premises, 1, -1 do
    local p = self.premises[i]
    if p and wanted[p.id] then
      removed[p.id] = copy_premise(p)
      self:remove_at(self.premises, i)
      any = true
    end
  end
  if any then
    self.premise_index = nil
    self.premise_buckets = nil
  end
  return removed
end

function Attempt:add_done(root_id, res, env)
  if counters_enabled then count('done.add') end
  self:set_field(self.done, root_id, { res = res, env = env })
end

function Attempt:add_group(gid, group)
  if counters_enabled then count('group.add') end
  self:set_field(self.groups, gid, group)
end

function Attempt:select_root(id)
  if counters_enabled then count('root.select') end
  self:set_field(self.selected, id, true)
end

local function make_rows_from_raw(lane_results)
  local rows = { _fibers_rows = true }
  for i = 1, #lane_results do rows[i] = copy_pack(lane_results[i].pack) end
  return rows
end

function collect_groups_from_stack(stack)
  local groups = {}
  local group_lanes = nil
  local node = stack
  while node do
    local f = node.frame
    if f and f.kind == 'product_lane' then
      groups[#groups + 1] = f.group_id
      group_lanes = group_lanes or {}
      group_lanes[f.group_id] = f.lane
    end
    node = node.parent
  end
  return groups, group_lanes
end

local function common_disallowed_group(st, a, b)
  if a.root_id ~= b.root_id then return false end
  for i = 1, #(a.groups or {}) do
    for j = 1, #(b.groups or {}) do
      if a.groups[i] == b.groups[j] then
        local g = st.groups[a.groups[i]]
        if g and not g.allow_internal then return true end
      end
    end
  end
  return false
end


-- Branch application and continuations -----------------------------------

local function settle_losing_nacks(op, out)
  if type(op) ~= 'table' then return end
  if op.kind == 'with_nack' then
    local ob = { state = 'pending' }
    out[#out + 1] = ob
    pcall(op.fn, { obligation = ob })
  elseif op.kind == 'choice' then
    for i = 1, #(op.choices or {}) do settle_losing_nacks(op.choices[i], out) end
  elseif op.kind == 'product' then
    for i = 1, #(op.lanes or {}) do settle_losing_nacks(op.lanes[i], out) end
  elseif op.kind == 'wrap' or op.kind == 'bind' or op.kind == 'map' then
    settle_losing_nacks(op_inner(op), out)
  elseif op.kind == 'or_else' then
    settle_losing_nacks(op_primary(op), out)
    settle_losing_nacks(op_fallback(op), out)
  elseif op.kind == 'guard' then
    -- Guard bodies are not run merely to inspect losing branches.
  end
end

local function callback_ctx(st)
  return {
    rt = st.rt,
    now = function() return st.rt and st.rt.now and st.rt:now() or 0 end,
    before = function(_self, deadline) return deadline end,
  }
end

local function call_callback(st, phase, fn, ...)
  local rt = st and st.rt
  if rt and rt._call_in_phase then
    return rt:_call_in_phase(phase, 'callback_error', fn, ...)
  end
  return fn(...)
end

local complete_task -- forward

local function complete_product_lane(st, task, frame, res)
  if counters_enabled then count('product.lane.complete') end
  local g = st.groups[frame.group_id]
  if not g then st:set_conflict('unknown-product-group'); return st end
  if g.results[frame.lane] then st:set_conflict('duplicate-product-lane'); return st end

  st:set_field(g.results, frame.lane, res)
  st:set_field(g.envs, frame.lane, Resources.copy_delta(task.env))
  st:set_field(g, 'done', (g.done or 0) + 1)

  if g.done < g.n then return st end

  local lane_envs = {}
  local lane_results = {}
  for i = 1, g.n do
    lane_results[i] = g.results[i]
    lane_envs[i] = g.envs[i]
  end
  local merged, reason = Resources.merge_lanes(g.parent_env, lane_envs)
  if not merged then st:set_conflict(reason or 'product-resource-conflict'); return st end

  local rows = make_rows_from_raw(lane_results)
  local pres = new_result(pack_(rows), lane_results)
  local parent = { root_id = g.root_id, op = nil, stack = g.parent_stack, env = merged, attempt = g.attempt }
  return complete_task(st, parent, pres)
end

complete_task = function(st, task, res)
  if counters_enabled then count('task.complete') end
  while true do
    local frame
    frame, task.stack = stack_pop(task.stack)
    if not frame then
      st:add_done(task.root_id, res, task.env)
      return st
    elseif frame.kind == 'bind' then
      local next_op = call_callback(st, 'bind', frame.fn, unpack_(res.pack, 1, res.pack.n))
      if type(next_op) ~= 'table' or not next_op.kind then error('and_then callback must return an option') end
      task.op = next_op
      st:push_task(task)
      return st
    elseif frame.kind == 'map' then
      res.pack = pack_(call_callback(st, 'map', frame.fn, unpack_(res.pack, 1, res.pack.n)))
    elseif frame.kind == 'wrap' then
      res.wraps[#res.wraps + 1] = frame.fn
    elseif frame.kind == 'product_lane' then
      return complete_product_lane(st, task, frame, res)
    else
      error('unknown continuation frame: ' .. tostring(frame.kind))
    end
  end
end

local function apply_task_step(st, idx, branch)
  if counters_enabled then count('task.step') end
  local task = st:remove_task(idx)
  local op = task.op
  task.op = nil
  if not op then return st end

  local k = op.kind
  if k == 'always' then
    return complete_task(st, task, new_result(op_values(op)))
  elseif k == 'bind' then
    task.stack = stack_push(task.stack, { kind = 'bind', fn = op.fn })
    task.op = op_inner(op)
    st:push_task(task)
    return st
  elseif k == 'map' then
    task.stack = stack_push(task.stack, { kind = 'map', fn = op.fn })
    task.op = op_inner(op)
    st:push_task(task)
    return st
  elseif k == 'wrap' then
    task.stack = stack_push(task.stack, { kind = 'wrap', fn = op.fn })
    task.op = op_inner(op)
    st:push_task(task)
    return st
  elseif k == 'guard' then
    local cache = task.attempt and task.attempt.guard_cache
    local key = op._id or op
    if cache and cache[key] ~= nil then
      task.op = cache[key]
    else
      task.op = call_callback(st, 'guard', op.fn, callback_ctx(st))
      if cache then cache[key] = task.op end
    end
    st:push_task(task)
    return st
  elseif k == 'nack' then
    local ref = op.obligation or op.ref
    if ref and ref.state == 'lost' then
      return complete_task(st, task, new_result(pack_(true)))
    end
    st:set_conflict('nack-not-lost')
    return st
  elseif k == 'with_nack' then
    local ob = { state = 'pending' }
    Resources.add_selected(task.env, ob)
    local next_op = call_callback(st, 'nack', op.fn, { obligation = ob })
    task.op = next_op
    st:push_task(task)
    return st
  elseif k == 'choice' then
    local choice_index = branch.choice_index
    task.op = op.choices[choice_index]
    for j = 1, #(op.choices or {}) do
      if j ~= choice_index then
        task.env.lost = task.env.lost or {}
        settle_losing_nacks(op.choices[j], task.env.lost)
      end
    end
    st:push_task(task)
    return st
  elseif k == 'or_else' then
    if branch.or_else_side == 'primary' then
      task.op = op_primary(op)
    else
      Resources.add_absence_cert(task.env, branch.cert)
      task.op = op_fallback(op)
    end
    st:push_task(task)
    return st
  elseif k == 'product' then
    st:set_field(st, 'next_group', st.next_group + 1)
    local gid = st.next_group
    local parent_stack = task.stack
    local parent_env = Resources.copy_env(task.env)
    local group = {
      n = #(op.lanes or {}),
      allow_internal = op.allow_internal == true,
      root_id = task.root_id,
      parent_stack = parent_stack,
      parent_env = parent_env,
      attempt = task.attempt,
      results = {}, envs = {}, done = 0,
    }
    st:add_group(gid, group)
    for i = 1, #op.lanes do
      local lt = {
        root_id = task.root_id,
        op = op.lanes[i],
        stack = parent_stack,
        env = Resources.lane_env_from(parent_env),
        attempt = task.attempt,
      }
      lt.stack = stack_push(lt.stack, { kind = 'product_lane', group_id = gid, lane = i })
      st:push_task(lt)
    end
    return st
  end

  if Resources.apply(st, task, op, complete_task, new_result) then
    return st
  else
    error('unknown option kind: ' .. tostring(k))
  end
end

local function apply_premise_solution(st, solution)
  if counters_enabled then count('premise.solution.apply') end
  local ids = solution.ids or {}
  local removed = st:remove_premises(ids)

  -- A premise solution may carry one shared proposal.  This is proof evidence
  -- for the solution as a whole, not a resource delta owned by one premise
  -- lane.  Resolved tasks therefore carry the same once-only contribution id;
  -- environment merges deduplicate it and final preparation expands it once.
  local contribution_id = solution.contribution_id or solution.id
  if solution.proposal then
    if not contribution_id then
      st:set_field(st, 'next_contribution', st.next_contribution + 1)
      contribution_id = 'premise-solution-' .. tostring(st.next_contribution)
    end
  end

  for i = 1, #ids do
    local id = ids[i]
    local p = removed[id]
    if not p then st:set_conflict('missing-premise'); return st end
    local vals = solution.results and solution.results[id]
    if not vals then st:set_conflict('missing-premise-result'); return st end
    if solution.proposal then
      local env, err = Resources.with_contribution_frame(p.task.env, contribution_id, solution.proposal)
      if not env then st:set_unknown(nil, err or 'premise-contribution-conflict'); return st end
      p.task.env = env
    end
    local proposal = solution.proposals and solution.proposals[id]
    if proposal then
      local ok, err = Resources.commit_candidate_into_env(p.task.env, proposal)
      if not ok then st:set_unknown(nil, err or 'premise-resource-conflict'); return st end
    end
    complete_task(st, p.task, new_result(vals))
    if st.conflict then return st end
  end
  return st
end

local function has_done(done)
  for _ in pairs(done) do return true end
  return false
end

local function sorted_premise_buckets(st)
  if st.premise_buckets then return st.premise_buckets end
  local idx = {}
  local buckets = {}
  for i = 1, #(st.premises or {}) do
    local p = st.premises[i]
    local bucket = idx[p.resource]
    if not bucket then
      bucket = { resource = p.resource, kind = p.kind, premises = {} }
      idx[p.resource] = bucket
      buckets[#buckets + 1] = bucket
    end
    bucket.premises[#bucket.premises + 1] = p
  end
  sort_premise_buckets(buckets)
  st.premise_index = idx
  st.premise_buckets = buckets
  return buckets
end

local function premise_absence_ctx(st, cert)
  local ctx = { rt = st.rt, observer = st.observer, capture = st.capture, observing = (st.observer ~= nil) or (st.capture and st.capture:frontiers_enabled()) }
  function ctx:observe_frontier(frontier)
    if frontier and self.observer then frontier:observe(self.observer) end
    return frontier and frontier.gen or nil
  end
  function ctx:add(obs)
    if obs then
      if obs.frontier and self.observer then obs.frontier:observe(self.observer) end
      cert:add(obs)
    end
  end
  return ctx
end

local function premise_outcome(st)
  if counters_enabled then count('premise.outcome') end
  local cert = AbsenceCert.new()
  local waits = {}
  local buckets = sorted_premise_buckets(st)
  for bi = 1, #buckets do
    local bucket = buckets[bi]
    local ps = {}
    for i = 1, #(bucket.premises or {}) do
      local p = bucket.premises[i]
      if p then
        ps[#ps + 1] = p
        if p.wait then waits[#waits + 1] = p.wait end
      end
    end
    local ok = false
    local absence = bucket.kind and bucket.kind.absence_premises
    if absence then
      ok = absence(bucket.resource, ps, premise_absence_ctx(st, cert)) == true
    end
    if not ok then
      for i = 1, #ps do
        local p = ps[i]
        cert:add({ kind = 'premise-absent', resource = p.resource, resource_kind = p.kind and p.kind.name, request = p.request })
      end
    end
  end
  return Outcome.miss(cert, waits)
end


-- Completed proof worlds --------------------------------------------------
-- A World is the completed proof object: selected roots, merged resource
-- environment, cached preparation, optional frontier observer, and delivery
-- functions.  Proof search may build it; commit is the only place that
-- applies prepared resource mutations.

local World = {}
World.__index = World

function World.from_attempt(st)
  if counters_enabled then count('world.from_attempt') end
  local ids = {}
  for id, _ in pairs(st.done) do ids[#ids + 1] = id end
  table.sort(ids)
  local merged = Resources.new_env(nil, st.capture)
  local roots = {}
  for _, id in ipairs(ids) do
    roots[id] = st.done[id].res
    local ok, err = Resources.merge_parallel_into(merged, st.done[id].env)
    if not ok then return nil, err end
  end
  local single_root_id = (#ids == 1) and ids[1] or nil
  return setmetatable({ roots = roots, single_root_id = single_root_id, env = merged, prepared = nil, observer = nil, valid = nil, consumed = false }, World)
end

local EMPTY_PREPARED = { resources = nil, effects = nil }
local EMPTY_ENV = {}

function World.local_root(root_id, res, env)
  if counters_enabled then count('world.local_root') end
  -- A zero-premise proof has no resource/environment delta to prepare.  It is
  -- still represented as an ordinary World so commit and delivery use the same
  -- semantic path as general proof-net search.
  env = env or EMPTY_ENV
  return setmetatable({ roots = { [root_id] = res }, single_root_id = root_id, direct_delivery = true, env = env, prepared = EMPTY_PREPARED, observer = nil, valid = true, consumed = false }, World)
end

function World:has_absence()
  return self.env and self.env.has_absence == true
end


function World:dispose_observer()
  if self.observer then
    self.observer:dispose()
    self.observer = nil
  end
end

function World:validate_debug_observations(rt)
  for i = 1, #(self.env.debug_observations or {}) do
    if not Resources.validate_observation(rt, self.env.debug_observations[i]) then return false end
  end
  for i = 1, #(self.env.debug_absence_observations or {}) do
    if not Resources.validate_observation(rt, self.env.debug_absence_observations[i]) then return false end
  end
  return true
end


function World:probe(rt)
  if counters_enabled then count('world.probe') end
  if self.consumed then return nil, 'consumed-world' end
  if self.prepared and self.valid ~= false then return true end

  self.observer = nil
  self.valid = true

  local prepared, reason = Resources.prepare_env(rt, self.env)
  if not prepared then
    self:dispose_observer()
    self.valid = false
    return nil, reason or 'prepare-refused'
  end

  self.prepared = prepared


  return true
end

function World:prepare(rt)
  if self.observer and not Resources.observer_valid(self.observer) then self.valid = false end
  if self.prepared and self.valid ~= false then return self.prepared end
  local ok, reason = self:probe(rt)
  if not ok then return nil, reason end
  return self.prepared
end

function World:settle_nacks()
  for i = 1, #(self.env.selected or {}) do self.env.selected[i].state = 'selected' end
  for i = 1, #(self.env.lost or {}) do self.env.lost[i].state = 'lost' end
end

local function post_for_result(res)
  local lane_posts = nil
  if res.lanes then
    for i = 1, #res.lanes do
      local lp = post_for_result(res.lanes[i])
      if lp then
        lane_posts = lane_posts or {}
        lane_posts[i] = lp
      end
    end
  end

  local has_wraps = #(res.wraps or {}) > 0
  if not lane_posts and not has_wraps then return nil end

  return function(vals)
    local p = copy_pack(vals)
    if lane_posts then
      local rows = p[1] or {}
      local out_rows = { _fibers_rows = true }
      for i = 1, #rows do
        local row = rows[i]
        if lane_posts[i] then row = lane_posts[i](row) end
        out_rows[i] = row
      end
      p = pack_(out_rows)
    end
    for i = 1, #(res.wraps or {}) do
      p = pack_(res.wraps[i](unpack_(p, 1, p.n)))
    end
    return p
  end
end

function World:delivery_for(_rt, id)
  local res = self.roots[id]
  if self.direct_delivery then return res.pack, post_for_result(res) end
  return copy_pack(res.pack), post_for_result(res)
end

function World:run_wraps_for(rt, id)
  local vals, post = self:delivery_for(rt, id)
  if post then vals = post(vals) end
  return vals
end

function World:commit(rt)
  if counters_enabled then count('world.commit') end
  if self.observer and not Resources.observer_valid(self.observer) then self.valid = false end
  if self.valid == false then return false, 'invalidated-world' end
  local prepared, reason = self:prepare(rt)
  if not prepared then return false, reason end
  if self.valid == false then return false, 'invalidated-world' end

  -- The committing world owns a proof that its observed frontiers are still
  -- live.  Dispose it before applying mutations so the world does not
  -- invalidate itself through its own writes.
  self:dispose_observer()

  Resources.apply_prepared(prepared)
  Resources.discharge_prepared(rt, prepared)
  self:settle_nacks()
  self.consumed = true
  self.valid = false
  return true
end

Net.World = World
Net.Attempt = Attempt


-- Solver, local proof reduction, and cursor support ----------------------

local Solver = {}
Solver.__index = Solver

local function task_branches(st)
  if counters_enabled then count('branches.task') end
  if #st.tasks == 0 then return nil end
  local op = st.tasks[1].op
  if op and op.kind == 'choice' then
    local branches = {}
    for i = 1, #(op.choices or {}) do branches[#branches + 1] = { kind = 'task', index = 1, choice_index = i } end
    return branches
  elseif op and op.kind == 'or_else' then
    return { { kind = 'task', index = 1, or_else_side = 'primary' } }
  else
    return { { kind = 'task', index = 1 } }
  end
end

local function premise_branches(st)
  if counters_enabled then count('branches.premise') end
  local branches = {}
  local ctx = {}
  function ctx:compatible(a, b)
    return not common_disallowed_group(st, a, b)
  end
  ctx.pack = pack_
  ctx.attempt = st
  function ctx:now() return self.attempt and self.attempt.rt and self.attempt.rt.now and self.attempt.rt:now() or 0 end

  local function premise_lane_for_group(premise, gid)
    local lanes = premise and premise.group_lanes
    if lanes then return lanes[gid] end
    local node = premise and premise.task and premise.task.stack or nil
    while node do
      local f = node.frame
      if f and f.kind == 'product_lane' and f.group_id == gid then return f.lane end
      node = node.parent
    end
    return nil
  end

  function ctx:resource_record_views(resource, premises)
    local out, seen = {}, {}

    local function add_env(env, relation, group, lane, delta_only)
      if not env then return end
      local by_relation = seen[env]
      if not by_relation then by_relation = {}; seen[env] = by_relation end
      local by_group = by_relation[relation]
      if not by_group then by_group = {}; by_relation[relation] = by_group end
      local group_key = group or false
      local by_lane = by_group[group_key]
      if not by_lane then by_lane = {}; by_group[group_key] = by_lane end
      local lane_key = lane or false
      if by_lane[lane_key] then return end
      by_lane[lane_key] = true

      local rec
      -- Hot path: most proof frames are parentless sparse deltas.  Trust that
      -- shape and inspect the record directly instead of flattening/copying the
      -- environment merely to discover that no relevant overlay exists.
      if not env.parent then
        rec = env.res and env.res[resource]
      elseif delta_only then
        local effective = Resources.copy_delta(env)
        local overlay = Resources.overlay_for_env(effective)
        rec = overlay and overlay.res and overlay.res[resource]
      else
        local overlay = Resources.overlay_for_env(env)
        rec = overlay and overlay.res and overlay.res[resource]
      end
      if rec then
        out[#out + 1] = {
          rec = rec,
          relation = relation,
          group = group,
          lane = lane,
          allow_internal = group and group.allow_internal == true or false,
        }
      end
    end

    for i = 1, #(premises or {}) do
      local p = premises[i]
      if p and p.task then add_env(p.task.env, 'own', nil, nil, true) end
      for gi = 1, #(p and p.groups or {}) do
        local gid = p.groups[gi]
        local g = st.groups[gid]
        if g then
          add_env(g.parent_env, 'outer', g, nil, false)
          local own_lane = premise_lane_for_group(p, gid)
          for lane = 1, (g.n or 0) do
            if g.envs and g.envs[lane] then
              local relation = (own_lane ~= nil and lane == own_lane) and 'own' or 'sibling'
              add_env(g.envs[lane], relation, g, lane, true)
            end
          end
        end
      end
    end
    return out
  end

  function ctx:resource_records(resource, premises)
    local views = self:resource_record_views(resource, premises)
    local out = {}
    for i = 1, #views do out[#out + 1] = views[i].rec end
    return out
  end

  local buckets = sorted_premise_buckets(st)
  for bi = 1, #buckets do
    local bucket = buckets[bi]
    local kind = bucket.kind
    local resolver = kind and kind.resolve_premises
    if resolver then
      local ps = bucket.premises or {}
      local sols = resolver(bucket.resource, ps, ctx) or {}
      for i = 1, #sols do
        branches[#branches + 1] = { kind = 'premise_solution', solution = sols[i] }
      end
    end
  end
  return branches
end

local function sorted_pending_ids(pending)
  local ids = {}
  for id, _ in pairs(pending or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function partner_branches(st)
  if counters_enabled then count('branches.partner') end
  local branches = {}
  local ids = st.pending_ids or sorted_pending_ids(st.pending)
  for i = 1, #ids do
    local id = ids[i]
    if not st.selected[id] then branches[#branches + 1] = { kind = 'partner', id = id } end
  end
  return branches
end

local function apply_branch(st, branch)
  if branch.kind == 'task' then
    return apply_task_step(st, branch.index, branch)
  elseif branch.kind == 'premise_solution' then
    return apply_premise_solution(st, branch.solution)
  elseif branch.kind == 'partner' then
    st:select_root(branch.id)
    st:push_task({ root_id = branch.id, op = st.pending[branch.id].op, stack = nil, env = Resources.new_env(nil, st.capture), attempt = st.pending[branch.id].attempt })
    return st
  else
    error('unknown search branch: ' .. tostring(branch.kind))
  end
end

local search_state

-- Branch application is speculative unless it produces the committed hit.
-- All search paths use this helper so cursor suspension and backtracking obey
-- the same rollback discipline.
local function try_branch(st, branch, depth, charge_kind)
  if counters_enabled then count('branch.try') end
  if charge_kind and st.charge then st:charge(charge_kind) end
  local mark = st:mark()
  apply_branch(st, branch)
  local out = search_state(st, depth + 1)
  if out.tag == 'hit' then return out end
  st:rollback(mark)
  -- Cached premise buckets are derived from the speculative premise list.
  -- They are intentionally not trailed, so discard them after any rollback.
  st.premise_index = nil
  st.premise_buckets = nil
  return out
end

local function search_or_else(st, depth)
  local primary = try_branch(st, { kind = 'task', index = 1, or_else_side = 'primary' }, depth, 'or-else-primary')
  if primary.tag == 'hit' then return primary end
  if primary.tag ~= 'miss' then return primary end
  local primary_cert = primary.cert or {}

  local fallback = try_branch(st, { kind = 'task', index = 1, or_else_side = 'fallback', cert = primary_cert }, depth, 'or-else-fallback')
  if fallback.tag == 'hit' then return fallback end

  local waits = {}
  append_all(waits, fallback.waits)
  if fallback.tag == 'unknown' then return Outcome.unknown(waits, fallback.reason) end
  local cert = AbsenceCert.new():extend(primary_cert):extend(fallback.cert)
  return Outcome.miss(cert, waits)
end

search_state = function(st, depth)
  if counters_enabled then count('search.state') end
  if depth > 800 then return Outcome.unknown({ { kind = 'budget' } }, 'budget') end
  if st.conflict then return st.outcome or Outcome.unknown(nil, st.conflict_reason) end

  if #st.tasks > 0 then
    local op = st.tasks[1].op
    if op and op.kind == 'or_else' then return search_or_else(st, depth) end
  end

  local branches = task_branches(st)
  if not branches then
    if #st.premises == 0 then
      if has_done(st.done) then
        local w = World.from_attempt(st)
        if w then
          local ok, reason = w:probe(st.rt)
          if ok then return Outcome.hit(w) end
          if reason == 'stale' or reason == 'stale-cursor' or reason == 'resource-not-fresh' or reason == 'stale-observation' then
            return Outcome.unknown(nil, reason)
          end
        end
        return Outcome.miss(AbsenceCert.new())
      end
      return Outcome.miss(AbsenceCert.new())
    end

    branches = premise_branches(st)
    local partners = partner_branches(st)
    for i = 1, #partners do branches[#branches + 1] = partners[i] end
    if #branches == 0 then return premise_outcome(st) end
  end


  local miss
  for i = 1, #branches do
    local out = try_branch(st, branches[i], depth, 'branch')
    if out.tag == 'hit' then return out end
    miss = Outcome.merge(miss, out)
  end
  return miss or Outcome.miss({})
end

function Solver.new(rt, pending)
  local self = setmetatable({
    rt = rt,
    pending = pending or {},
    pending_ids = sorted_pending_ids(pending or {}),
    waits = {},
    capture = Capture.none(),
    observer = nil,
    budget = nil,
    budget_used = 0,
    budget_exhausted = false,
    cursor = nil,
  }, Solver)
  return self
end
function Solver:charge(kind)
  if counters_enabled then count('charge.' .. tostring(kind)) end
  if self.cursor and self.cursor.charge then self.cursor:charge(kind) end
end

local function append_waits(dst, src)
  for i = 1, #(src or {}) do dst[#dst + 1] = src[i] end
end


local function local_nonlocal_kind(op)
  if type(op) ~= 'table' then return true end
  local k = op.kind
  if k == 'always' or k == 'bind' or k == 'map' or k == 'wrap' or k == 'guard' then return false end
  return true
end

local function op_summary(op)
  if type(op) ~= 'table' then return { may_start_local = false, static_local = false } end
  local cached = rawget(op, '_net_summary')
  if cached then return cached end

  local k = op.kind
  local summary
  if k == 'always' then
    summary = { may_start_local = true, static_local = true }
  elseif k == 'wrap' or k == 'map' then
    local inner = op_summary(op_inner(op))
    summary = {
      may_start_local = true,
      static_local = inner.static_local == true,
    }
  elseif k == 'bind' then
    -- A bind may stay inside local proof reduction, but only after running the
    -- callback.  The cached summary therefore authorises entering the corridor
    -- without claiming that the whole option is statically local.
    summary = { may_start_local = true, static_local = false }
  elseif k == 'guard' then
    -- A guard is search-phase construction.  It may produce a local proof or a
    -- genuine net premise, so it can enter the corridor but is never static.
    summary = { may_start_local = true, static_local = false }
  elseif k == 'prim' and op.prim == 'resource' then
    local rs = Resources.primitive_summary(op) or {}
    summary = {
      may_start_local = false,
      static_local = false,
      primitive = true,
      resources = rs.resources == true,
      endpoints = rs.endpoints == true,
      dynamic = rs.dynamic == true,
      reads = rs.reads == true,
      writes = rs.writes == true,
      closed = rs.closed == true,
      needs_overlay = rs.needs_overlay == true,
    }
  else
    summary = { may_start_local = false, static_local = false }
  end

  rawset(op, '_net_summary', summary)
  return summary
end

local LOCAL_DONE = 'done'          -- zero-premise proof completed with a result
local LOCAL_MISS = 'miss'          -- structural absence
local LOCAL_CONTINUE = 'continue'  -- a bind supplied another local option
local LOCAL_NEEDS_NET = 'needs-net' -- reduction reached a real proof-net premise

-- Local proof reduction is a proof-net phase, not a runtime bypass.  It may
-- reduce only deterministic zero-premise forms: always, bind while the bind
-- result remains local, wrap, and guard construction.  It must
-- not observe, prepare, or commit resources.  When it reaches a resource,
-- rendezvous, product, choice, or absence question, the same task is passed back
-- to general search so callbacks already run are not repeated.
local function reduce_local_task(solver, task)
  if counters_enabled then count('local.reduce') end
  local st = { rt = solver.rt }
  local res = nil

  local function finish_result()
    while true do
      if solver.charge then solver:charge('local-frame') end
      local frame
    frame, task.stack = stack_pop(task.stack)
      if not frame then return LOCAL_DONE, res end
      if frame.kind == 'bind' then
        local next_op = call_callback(st, 'bind', frame.fn, unpack_(res.pack, 1, res.pack.n))
        if type(next_op) ~= 'table' or not next_op.kind then error('and_then callback must return an option') end
        task.op = next_op
        res = nil
        return LOCAL_CONTINUE
      elseif frame.kind == 'map' then
        res.pack = pack_(call_callback(st, 'map', frame.fn, unpack_(res.pack, 1, res.pack.n)))
      elseif frame.kind == 'wrap' then
        res.wraps[#res.wraps + 1] = frame.fn
      else
        return LOCAL_NEEDS_NET
      end
    end
  end

  while true do
    if solver.charge then solver:charge('local-op') end
    local op = task.op
    task.op = nil
    if not op then return LOCAL_NEEDS_NET end
    local k = op.kind

    if k == 'always' then
      res = new_result(op_values(op))
      local status, out = finish_result()
      if status == LOCAL_CONTINUE then
        -- The bind continuation supplied another option.  Keep reducing it
        -- while it remains inside the deterministic zero-premise corridor.
      else
        return status, out
      end
    elseif k == 'bind' then
      task.stack = stack_push(task.stack, { kind = 'bind', fn = op.fn })
      task.op = op_inner(op)
    elseif k == 'map' then
      task.stack = stack_push(task.stack, { kind = 'map', fn = op.fn })
      task.op = op_inner(op)
    elseif k == 'wrap' then
      task.stack = stack_push(task.stack, { kind = 'wrap', fn = op.fn })
      task.op = op_inner(op)
    elseif k == 'guard' then
      local cache = task.attempt and task.attempt.guard_cache
      local key = op._id or op
      if cache and cache[key] ~= nil then
        task.op = cache[key]
      else
        task.op = call_callback(st, 'guard', op.fn, callback_ctx(st))
        if cache then cache[key] = task.op end
      end
    elseif local_nonlocal_kind(op) then
      task.op = op
      return LOCAL_NEEDS_NET
    else
      task.op = op
      return LOCAL_NEEDS_NET
    end
  end
end

function Solver:find_local_or_out_from(id)
  if not self.pending[id] then return Outcome.miss(AbsenceCert.new()) end

  local p = self.pending[id]
  local summary = op_summary(p.op)
  if not summary.may_start_local then
    local attempt = Attempt.new(self.rt, self.pending, id, self)
    local out = search_state(attempt, 0)
    if out.tag ~= 'hit' then append_waits(self.waits, out.waits or attempt.frontier_waits) end
    return out
  end

  local task = {
    root_id = id,
    op = p.op,
    stack = nil,
    env = nil,
    attempt = p.attempt,
  }

  local status, res = reduce_local_task(self, task)
  if status == LOCAL_DONE then
    local world, err = World.local_root(id, res, task.env)
    if not world then return Outcome.unknown(nil, err) end
    return Outcome.hit(world)
  elseif status == LOCAL_MISS then
    return Outcome.miss(AbsenceCert.new())
  end

  -- The local corridor reached a genuine proof-net premise, for example a
  -- resource, rendezvous, branch or product.  Continue the same proof search from
  -- the reduced task rather than re-running any speculative algebra callbacks.
  local attempt = Attempt.new(self.rt, self.pending, id, self)
  task.env = task.env or Resources.new_env(nil, self.capture)
  attempt.tasks[1] = task
  local out = search_state(attempt, 0)
  if out.tag ~= 'hit' then append_waits(self.waits, out.waits or attempt.frontier_waits) end
  return out
end

function Solver:find_out_from(id)
  if not self.pending[id] then return Outcome.miss(AbsenceCert.new()) end
  local attempt = Attempt.new(self.rt, self.pending, id, self)
  local out = search_state(attempt, 0)
  if out.tag ~= 'hit' then append_waits(self.waits, out.waits or attempt.frontier_waits) end
  return out
end

function Solver:find_from(id)
  local out = self:find_out_from(id)
  return out.tag == 'hit' and out.world or nil
end

function Solver:find_commit_outcome()
  if counters_enabled then count('solver.find_commit_outcome') end
  local ids = self.pending_ids or sorted_pending_ids(self.pending)

  if #ids == 1 then
    self:charge('root-scan')
    return self:find_local_or_out_from(ids[1])
  end

  -- Absence-certified fallback is deliberately lowest priority.  A fallback
  -- world is a claim that no preferred world is presently available; before
  -- committing it, ask every waiting root whether it can produce a non-absence
  -- world.  This prevents resource, task, and flow progress in another fibre
  -- from being masked by a too-local or_else fallback.
  local fallback_world = nil
  local miss = nil
  for _, id in ipairs(ids) do
    self:charge('root-scan')
    local out = self:find_out_from(id)
    if out.tag == 'hit' then
      local w = out.world
      if not w:has_absence() then return Outcome.hit(w) end
      fallback_world = fallback_world or w
    elseif out.tag == 'unknown' then
      return out
    else
      miss = Outcome.merge(miss, out)
    end
  end
  if fallback_world then return Outcome.hit(fallback_world) end
  return miss or Outcome.miss(AbsenceCert.new(), self.waits)
end

function Solver:find_commit_candidate()
  local out = self:find_commit_outcome()
  return out.tag == 'hit' and out.world or nil
end

local Cursor = {}
Cursor.__index = Cursor

local function pending_signature(pending)
  local ids = {}
  for id, _ in pairs(pending or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for i = 1, #ids do
    local id = ids[i]
    local p = pending[id]
    parts[#parts + 1] = tostring(id)
    parts[#parts + 1] = tostring(p and p.fiber)
    parts[#parts + 1] = tostring(p and p.op)
    parts[#parts + 1] = tostring(p and p.attempt)
  end
  return table.concat(parts, '\0')
end

Net.pending_signature = pending_signature

function Cursor.new(solver)
  local self = setmetatable({
    solver = solver,
    rt = solver.rt,
    pending_sig = pending_signature(solver.pending),
    limit = nil,
    used = 0,
    co = nil,
    observer = nil,
    valid = true,
  }, Cursor)

  self.observer = Resources.new_observer('cursor', self)
  solver.capture = Capture.frontiers()
  solver.cursor = self
  solver.observer = self.observer
  self.co = coroutine.create(function()
    return solver:find_commit_outcome()
  end)
  return self
end


function Cursor:dispose()
  if self.observer then
    self.observer:dispose()
    self.observer = nil
  end
  if self.solver and self.solver.observer and self.solver.observer.owner == self then
    self.solver.observer = nil
  end
end

function Cursor:take_observer()
  local observer = self.observer
  self.observer = nil
  if self.solver and self.solver.observer == observer then self.solver.observer = nil end
  return observer
end

function Cursor:is_valid(rt, pending)
  return self.rt == rt
     and self.valid ~= false
     and self.observer ~= nil
     and Resources.observer_valid(self.observer)
     and self.pending_sig == pending_signature(pending)
     and self.co ~= nil
     and coroutine.status(self.co) ~= 'dead'
end

function Cursor:charge(kind)
  if not self.limit then return end
  if self.used >= self.limit then
    coroutine.yield({ tag = 'budget', kind = kind, used = self.used })
  end
  self.used = self.used + 1
end

function Cursor:advance(max_work)
  local n = tonumber(max_work) or 1
  if n < 1 then n = 1 end
  self.limit = math.floor(n)
  self.used = 0

  local ok, out = coroutine.resume(self.co)
  if not ok then error(out, 0) end

  if coroutine.status(self.co) ~= 'dead' then
    if type(out) == 'table' and out.tag == 'budget' then
      out.cursor = self
      return out
    end
    error('transaction-net cursor yielded unexpected value')
  end

  self.solver.cursor = nil
  return out
end

Net.Cursor = Cursor

function Solver:new_cursor()
  return Cursor.new(self)
end

function Solver:advance(cursor, max_work)
  cursor = cursor or self:new_cursor()
  return cursor:advance(max_work)
end

function Solver:perform_sync(op)
  local pseudo = { op = op, fiber = nil }
  local pending = { [1] = pseudo }
  local out = search_state(Attempt.new(self.rt, pending, 1), 0)
  if out.tag ~= 'hit' then return { tag = out.tag == 'miss' and 'absent' or 'pending' }, pack_() end
  local world = out.world
  local ok = world:commit(self.rt)
  if not ok then return { tag = 'pending' }, pack_() end
  local p = world:run_wraps_for(self.rt, 1)
  return { tag = 'found' }, p
end

Net.Solver = Solver
return Net
