-- This module is the boundary between the algebraic transaction search and the
-- mutable/external world.  Resource kinds own their local frontier protocol:
-- clone/merge/project/prepare/apply for committed deltas, plus optional leaf
-- miss certification.  The transaction net owns option algebra; resource
-- kinds only certify local mutable facts.

local Op = require('fibers.atoms.op')
local Wait = require('fibers.kernel.wait')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local EffectSet = require('fibers.kernel.effect.set')
local ContributionSet = require('fibers.kernel.resources.contribution_set')
local FrontierKit = require('fibers.kernel.frontier')
local Proof = require('fibers.kernel.proof')
local AbsenceCert = Proof.AbsenceCert
local Capture = Proof.Capture

local Resources = {}

-- Optional resource-layer counters.  Disabled by default; enable with
-- FIBERS_COUNTERS=1 or Resources.enable_counters(true).
local counters_enabled = os.getenv('FIBERS_COUNTERS') == '1'
local counters = {}

local function count(kind, n)
  if not counters_enabled then return end
  counters[kind] = (counters[kind] or 0) + (n or 1)
end

function Resources.enable_counters(enabled)
  counters_enabled = enabled ~= false
  counters = {}
end

function Resources.reset_counters() counters = {} end

function Resources.counters()
  local out = {}
  for k, v in pairs(counters) do out[k] = v end
  return out
end

local runtime_now

local pack_ = Op._pack
local unpack_ = Op._unpack

local function append(out, item) out[#out + 1] = item end

local function copy_list(xs)
  if not xs then return nil end
  local out = {}
  for i = 1, #xs do out[i] = xs[i] end
  return out
end

local function append_list(dst, src)
  if not dst or not src then return end
  for i = 1, #src do dst[#dst + 1] = src[i] end
end

local function append_field(dst, field, src)
  if not src or #src == 0 then return end
  local out = dst[field]
  if not out then out = {}; dst[field] = out end
  append_list(out, src)
end

local function require_frontier(obj, label, kind, key)
  if obj == nil then error('managed validity frontier required for nil ' .. tostring(label or 'object'), 3) end
  local v = rawget(obj, '_validity')
  if v and v.frontier_for then return v:frontier_for(kind or label, key) end
  v = rawget(obj, '_validity_opaque')
  if v and v.frontier_for then return v:frontier_for(kind or label, key) end
  v = rawget(obj, '_validity_value')
  if v and v.frontier_for then return v:frontier_for(kind or label, key) end
  error('resource ' .. tostring(obj._fibers_id or obj.name or obj) .. ' lacks managed validity fact for ' .. tostring(label or kind or 'frontier'), 3)
end

local function object_validity_frontier(obj)
  return require_frontier(obj, 'version')
end


local function clock_before_frontier(source, deadline)
  local v = source and rawget(source, '_validity')
  if not (v and v.before_frontier) then
    error('clock source ' .. tostring(source and (source._fibers_id or source.name) or source) .. ' lacks managed clock validity', 3)
  end
  return v:before_frontier(deadline)
end

local function register_clock_source(rt, source)
  if not (rt and source) then return end
  rt._clock_sources = rt._clock_sources or setmetatable({}, { __mode = 'k' })
  rt._clock_sources[source] = true
end

local function add_frontier_to_env(env, frontier)
  if not env or not frontier or not (env.capture and env.capture:frontiers_enabled()) then return end
  env.frontiers = env.frontiers or {}
  env.frontier_seen = env.frontier_seen or {}
  if not env.frontier_seen[frontier] then
    env.frontier_seen[frontier] = true
    env.frontiers[#env.frontiers + 1] = frontier
  end
end

local function obs_frontier(obs)
  return obs and obs.frontier or nil
end

local function copy_effects(set)
  return set and set:copy() or nil
end

local function copy_contributions(set)
  return set and set:copy() or nil
end

function Resources.new_env(parent, capture)
  if counters_enabled then count('env.new') end
  capture = capture or (parent and parent.capture) or Capture.none()
  return {
    res = nil,
    res_list = nil,
    effects = nil,
    contributions = nil,
    selected = nil,
    lost = nil,
    debug_observations = nil,
    debug_absence_observations = nil,
    frontiers = nil,
    frontier_seen = nil,
    capture = capture,
    has_absence = false,
    parent = parent,
    parent_is_boundary = false,
  }
end
function Resources.copy_env(env)
  if counters_enabled then count('env.copy') end
  if not env then return Resources.new_env() end
  local out = Resources.new_env(env.parent and Resources.copy_env(env.parent) or nil, env.capture)
  Resource.copy_from(out, env)
  out.effects = copy_effects(env.effects)
  out.contributions = copy_contributions(env.contributions)
  out.selected = copy_list(env.selected)
  out.lost = copy_list(env.lost)
  out.debug_observations = copy_list(env.debug_observations)
  out.debug_absence_observations = copy_list(env.debug_absence_observations)
  out.frontiers = copy_list(env.frontiers)
  if out.frontiers and #out.frontiers > 0 then
    out.frontier_seen = {}
    for i = 1, #out.frontiers do out.frontier_seen[out.frontiers[i]] = true end
  end
  out.has_absence = env.has_absence or false
  out.parent_is_boundary = env.parent_is_boundary or false
  return out
end

function Resources.lane_env_from(parent)
  if counters_enabled then count('env.lane') end
  local env = Resources.new_env(parent)
  env.parent_is_boundary = true
  return env
end

local function copy_without_parent(env)
  if counters_enabled then count('env.copy_without_parent') end
  local out = Resources.new_env(nil, env.capture)
  Resource.copy_from(out, env)
  out.effects = copy_effects(env.effects)
  out.contributions = copy_contributions(env.contributions)
  out.selected = copy_list(env.selected)
  out.lost = copy_list(env.lost)
  out.debug_observations = copy_list(env.debug_observations)
  out.debug_absence_observations = copy_list(env.debug_absence_observations)
  out.frontiers = copy_list(env.frontiers)
  if out.frontiers and #out.frontiers > 0 then
    out.frontier_seen = {}
    for i = 1, #out.frontiers do out.frontier_seen[out.frontiers[i]] = true end
  end
  out.has_absence = env.has_absence or false
  out.parent_is_boundary = false
  return out
end

local flatten_env

local function merge_contribution_proposals_seq(acc, contributions)
  if not contributions or contributions:is_empty() then return true end
  local items = contributions:items()
  local cenv = Resources.new_env(nil, acc.capture)
  for i = 1, #items do
    local p = items[i].proposal
    local ok, err = Resource.merge_parallel_into(cenv, p)
    if not ok then return false, err end
    if p.effects then
      cenv.effects = cenv.effects or EffectSet.empty()
      ok, err = cenv.effects:merge(p.effects)
      if not ok then return false, err end
    end
    append_field(cenv, 'selected', p.selected_nacks)
    append_field(cenv, 'lost', p.lost_nacks)
  end
  return Resources.merge_seq_into(acc, cenv)
end

local function collect_env_frames(env, include_boundary_parent)
  local frames = {}
  local e = env
  while e do
    frames[#frames + 1] = e
    if e.parent and e.parent_is_boundary and not include_boundary_parent then break end
    e = e.parent
  end
  local ordered = {}
  for i = #frames, 1, -1 do ordered[#ordered + 1] = frames[i] end
  return ordered
end

flatten_env = function(env, include_boundary_parent)
  if counters_enabled then count('env.flatten') end
  if not env then return Resources.new_env(nil) end
  local out = Resources.new_env(nil, env.capture)
  local frames = collect_env_frames(env, include_boundary_parent)
  for i = 1, #frames do
    local frame = copy_without_parent(frames[i])
    local contributions = frame.contributions
    frame.contributions = nil
    local ok, err = Resources.merge_seq_into(out, frame)
    if not ok then return nil, err end
    ok, err = merge_contribution_proposals_seq(out, contributions)
    if not ok then return nil, err end
  end
  return out
end

function Resources.flatten_env(env, include_boundary_parent)
  return flatten_env(env, include_boundary_parent ~= false)
end

function Resources.copy_delta(env)
  if counters_enabled then count('env.copy_delta') end
  if not env then return Resources.new_env() end
  local flat, err = flatten_env(env, false)
  if not flat then error(err or 'resource-delta-flatten-failed', 2) end
  return flat
end

function Resources.overlay_for_env(env)
  if counters_enabled then count('env.overlay') end
  if not env then return nil end
  local flat, err = flatten_env(env, true)
  if not flat then return nil, err end
  if not flat.res_list then return nil end
  return flat
end

local LazyOverlay = {}
LazyOverlay.__index = function(self, key)
  if key == 'res' or key == 'res_list' then
    local overlay = LazyOverlay.get(self)
    return overlay and overlay[key] or nil
  end
  return LazyOverlay[key]
end

function LazyOverlay:get()
  if self.loaded then return self.overlay end
  self.loaded = true
  local overlay, err = Resources.overlay_for_env(self.env)
  self.overlay = overlay or nil
  self.err = err
  -- Cache the hot fields directly on the proxy after the first projection.
  -- Code that performs multiple `ctx.overlay.res[...]` lookups then pays the
  -- metamethod only once.
  self.res = overlay and overlay.res or nil
  self.res_list = overlay and overlay.res_list or nil
  return self.overlay
end

function Resources.lazy_overlay_for_env(env)
  if counters_enabled then count('env.lazy_overlay') end
  if not env then return nil end
  return setmetatable({ env = env, loaded = false, overlay = nil, err = nil }, LazyOverlay)
end

local function merge_effect_sets_seq(dst, src)
  if not src then return true end
  dst.effects = dst.effects or EffectSet.empty()
  local ok, err = dst.effects:merge(src)
  if not ok then return false, err end
  return true
end

local function merge_contribution_sets(dst, src)
  if not src then return true end
  dst.contributions = dst.contributions or ContributionSet.empty()
  local ok, err = dst.contributions:merge(src)
  if not ok then return false, err end
  return true
end

function Resources.merge_seq_into(dst, src)
  if counters_enabled then count('merge.seq') end
  if src.parent then
    local flat, err = flatten_env(src, true)
    if not flat then return false, err end
    src = flat
  end
  local ok, err = Resource.merge_seq_into(dst, src)
  if not ok then return false, err end
  ok, err = merge_effect_sets_seq(dst, src.effects)
  if not ok then return false, err end
  ok, err = merge_contribution_sets(dst, src.contributions)
  if not ok then return false, err end
  append_field(dst, 'selected', src.selected)
  append_field(dst, 'lost', src.lost)
  append_field(dst, 'debug_observations', src.debug_observations)
  append_field(dst, 'debug_absence_observations', src.debug_absence_observations)
  for i = 1, #(src.frontiers or {}) do add_frontier_to_env(dst, src.frontiers[i]) end
  if src.has_absence then dst.has_absence = true end
  return true
end

function Resources.merge_parallel_into(dst, src)
  if counters_enabled then count('merge.parallel') end
  if src.parent then
    local flat, err = flatten_env(src, true)
    if not flat then return false, err end
    src = flat
  end
  local ok, err = Resource.merge_parallel_into(dst, src)
  if not ok then return false, err end
  ok, err = merge_effect_sets_seq(dst, src.effects)
  if not ok then return false, err end
  ok, err = merge_contribution_sets(dst, src.contributions)
  if not ok then return false, err end
  append_field(dst, 'selected', src.selected)
  append_field(dst, 'lost', src.lost)
  append_field(dst, 'debug_observations', src.debug_observations)
  append_field(dst, 'debug_absence_observations', src.debug_absence_observations)
  for i = 1, #(src.frontiers or {}) do add_frontier_to_env(dst, src.frontiers[i]) end
  if src.has_absence then dst.has_absence = true end
  return true
end

function Resources.merge_lanes(parent, lanes)
  if counters_enabled then count('merge.lanes') end
  local lane_acc = Resources.new_env(nil, parent and parent.capture)
  for i = 1, #(lanes or {}) do
    local ok, err = Resources.merge_parallel_into(lane_acc, lanes[i])
    if not ok then return nil, err end
  end
  local merged = Resources.copy_env(parent)
  local ok, err = Resources.merge_seq_into(merged, lane_acc)
  if not ok then return nil, err end
  return merged
end

function Resources.add_effect(env, effect)
  env.effects = env.effects or EffectSet.empty()
  return env.effects:add(effect)
end

function Resources.add_contribution(env, id, proposal)
  env.contributions = env.contributions or ContributionSet.empty()
  return env.contributions:add(id, proposal)
end

function Resources.with_contribution_frame(env, id, proposal)
  local frame = Resources.new_env(env, env and env.capture or nil)
  local ok, err = Resources.add_contribution(frame, id, proposal)
  if not ok then return nil, err end
  return Resources.new_env(frame, env and env.capture or nil)
end

function Resources.add_selected(env, item) env.selected = env.selected or {}; env.selected[#env.selected + 1] = item end
function Resources.add_lost(env, item) env.lost = env.lost or {}; env.lost[#env.lost + 1] = item end
function Resources.add_frontier(env, frontier)
  add_frontier_to_env(env, frontier)
end

function Resources.add_observation(env, obs)
  if env.capture and env.capture:debug_enabled() then
    env.debug_observations = env.debug_observations or {}
    env.debug_observations[#env.debug_observations + 1] = obs
  end
  add_frontier_to_env(env, obs_frontier(obs))
end

function Resources.add_absence_cert(env, cert)
  for i = 1, #(cert or {}) do
    local obs = cert[i]
    if env.capture and env.capture:debug_enabled() then
      env.debug_absence_observations = env.debug_absence_observations or {}
      env.debug_absence_observations[#env.debug_absence_observations + 1] = obs
    end
    add_frontier_to_env(env, obs_frontier(obs))
  end
  env.has_absence = true
end

function Resources.register_frontiers(frontiers, observer)
  if not observer then return end
  for i = 1, #(frontiers or {}) do frontiers[i]:observe(observer) end
end

function Resources.register_env_frontiers(env, observer)
  return Resources.register_frontiers(env and env.frontiers, observer)
end

function Resources.new_observer(kind, owner)
  return FrontierKit.Observer.new(kind, owner)
end


function Resources.observer_valid(observer)
  if observer == nil then return false end
  if observer.validate then return observer:validate() end
  return observer.valid ~= false
end


function Resources.invalidate_matured_clock_frontiers(rt)
  local now = runtime_now(rt)
  if rt and rt._clock_sources then
    for source in pairs(rt._clock_sources) do
      local v = source and source._validity
      if v and v.invalidate_matured then v:invalidate_matured(now) end
    end
  end
end

function Resources.observe_frontier(ctx, frontier, env)
  if not frontier then return nil end
  if ctx and ((ctx.capture and ctx.capture:frontiers_enabled()) or ctx.observer) then add_frontier_to_env(env, frontier) end
  if ctx and ctx.observer then frontier:observe(ctx.observer) end
  return frontier.gen
end

function Resources.invalidate_object(obj, reason)
  local v = obj and rawget(obj, '_validity_opaque')
  if v and v.bump then v:bump(reason); return end
  v = obj and rawget(obj, '_validity_value')
  if v and v.bump then v:bump(reason); return end
  v = obj and rawget(obj, '_validity')
  if v and v.bump then v:bump(reason); return end
  error('resource ' .. tostring(obj and (obj._fibers_id or obj.name) or obj) .. ' lacks managed validity fact for invalidation', 2)
end

local function object_version(obj) return (obj and (obj.version or obj.owner_version)) or 0 end
local function stamp(frontier) return frontier and (frontier.gen or 0) or nil end

runtime_now = function(rt)
  if rt and rt.now then return rt:now() end
  local host = rt and rt.host or nil
  if host and host.now then return host.now(rt) end
  return 0
end




local function primitive_resource(op)
  if type(op) ~= 'table' or op.kind ~= 'prim' or op.prim ~= 'resource' then return nil end
  return op.resource, op.resource_kind, op.payload or {}
end

function Resources.primitive_summary(op)
  local _resource, kind, payload = primitive_resource(op)
  if not kind then return nil end
  local cached = rawget(op, '_resource_summary')
  if cached then return cached end

  local out = { primitive = true, resources = false, endpoints = false, dynamic = false, reads = false, writes = false }
  if type(kind.summary) == 'function' then
    kind.summary(payload, out)
  else
    -- Unknown resource kinds keep the old conservative representation.
    out.dynamic = true
    out.closed = false
    out.needs_overlay = true
  end
  if out.closed == nil then out.closed = false end
  if out.needs_overlay == nil then out.needs_overlay = out.reads == true end
  rawset(op, '_resource_summary', out)
  return out
end

local function make_resource_ctx(st, task, summary)
  local observing = (st.capture and st.capture:frontiers_enabled()) or (st.observer ~= nil) or (task.env.capture and task.env.capture:debug_enabled())
  local ctx = {
    rt = st.rt,
    overlay = (not summary or summary.needs_overlay ~= false) and Resources.lazy_overlay_for_env(task.env) or nil,
    origin = task.root_id,
    observer = st.observer,
    capture = st.capture,
    observing = observing,
  }
  function ctx:observe_frontier(frontier)
    Resources.observe_frontier(self, frontier, task.env)
    return frontier and frontier.gen or nil
  end
  function ctx:observe_version(obj)
    local v = object_version(obj)
    if not ((self.capture and self.capture:frontiers_enabled()) or self.observer or (task.env.capture and task.env.capture:debug_enabled())) then return v end
    local frontier = object_validity_frontier(obj)
    Resources.observe_frontier(self, frontier, task.env)
    Resources.add_observation(task.env, { kind = 'version', object = obj, version = v, frontier = frontier })
    return v
  end
  function ctx:before(source, deadline)
    if deadline == nil then deadline, source = source, nil end
    if not ((self.capture and self.capture:frontiers_enabled()) or self.observer or (task.env.capture and task.env.capture:debug_enabled())) then return deadline end
    register_clock_source(st.rt, source)
    local frontier = clock_before_frontier(source, deadline)
    Resources.observe_frontier(self, frontier, task.env)
    Resources.add_observation(task.env, { kind = 'clock-before-selected', source = source, deadline = deadline, observed_now = runtime_now(st.rt), frontier = frontier })
    return deadline
  end
  function ctx:now() return runtime_now(st.rt) end
  return ctx
end

function Resources.commit_candidate_into_env(env, c)
  if counters_enabled then count('candidate.commit_into_env') end
  local ok, err = Resource.merge_seq_into(env, c)
  if not ok then return false, err end
  if c.effects then
    env.effects = env.effects or EffectSet.empty()
    ok, err = env.effects:merge(c.effects)
    if not ok then return false, err end
  end
  append_field(env, 'selected', c.selected_nacks)
  append_field(env, 'lost', c.lost_nacks)
  return true
end

function Resources.apply(st, task, op, complete_task, new_result)
  if counters_enabled then count('apply') end
  if op.kind == 'emit' then
    local ok, err = Resources.add_effect(task.env, op.effect)
    if not ok then st:set_unknown(nil, err or 'effect-conflict') else complete_task(st, task, new_result(pack_(true))) end
    return true
  end

  local resource, kind, payload = primitive_resource(op)
  if not resource then return false end
  local eval = kind and kind.eval
  if not eval then error('resource primitive requires kind.eval', 2) end

  local summary = Resources.primitive_summary(op)
  local ctx = make_resource_ctx(st, task, summary)
  local r = Result.from(eval(resource, payload, ctx))
  if r.status == 'premise' then
    if not st.push_premise then st:set_unknown(nil, 'premise-unsupported'); return true end
    st:push_premise({
      resource = resource,
      kind = kind,
      payload = payload,
      request = r.premise,
      wait = r.wait,
      task = task,
    })
    return true
  end
  if r.status == 'wait' or r.status ~= 'ready' then
    local cert = AbsenceCert.new()
    if Resources.absence_leaf(st.rt, op, cert, st.observer, st.capture) then
      st:set_miss(cert, r.status == 'wait' and { r.wait } or nil)
    else
      st:set_unknown(r.status == 'wait' and { r.wait } or nil, 'resource-blocked')
    end
    return true
  end

  local c = r.proposal
  local ok, err = Resources.commit_candidate_into_env(task.env, c)
  if not ok then st:set_unknown(nil, err or 'resource-conflict'); return true end
  local vals = Proposal.resolve_pack(c.vals, c.subst)
  complete_task(st, task, new_result(vals))
  return true
end

local function absence_ctx(rt, out, observer, capture)
  local ctx = { rt = rt, observer = observer, capture = capture, observing = (observer ~= nil) or (capture and capture:frontiers_enabled()) }
  function ctx:observe_frontier(frontier)
    if frontier and self.observer then frontier:observe(self.observer) end
    return frontier and frontier.gen or nil
  end
  function ctx:observe_version(obj, label)
    if obj ~= nil then
      local frontier
      if self.observer or (self.capture and self.capture:frontiers_enabled()) then frontier = object_validity_frontier(obj) end
      if frontier and self.observer then frontier:observe(self.observer) end
      append(out, { kind = 'version', object = obj, version = object_version(obj), label = label, frontier = frontier })
    end
    return obj and object_version(obj) or 0
  end
  function ctx:add(obs)
    if obs then
      if obs.frontier and self.observer then obs.frontier:observe(self.observer) end
      append(out, obs)
    end
  end
  function ctx:now() return runtime_now(rt) end
  return ctx
end

function Resources.absence_leaf(rt, op, out, observer, capture)
  if counters_enabled then count('absence.leaf') end
  local resource, kind, payload = primitive_resource(op)
  if not resource or not kind or type(kind.absence) ~= 'function' then return false end
  local before = #out
  local ok = kind.absence(resource, payload or {}, absence_ctx(rt, out, observer, capture))
  return ok == true or #out > before
end
function Resources.validate_observation(rt, obs)
  if obs.frontier and obs.stamp ~= nil and (obs.frontier.gen or 0) ~= obs.stamp then return false end
  local k = obs.kind
  if k == 'version' then
    return object_version(obs.object) == obs.version
  elseif k == 'signal-absent' then
    return not obs.source._validity.ready
  elseif k == 'events-empty' then
    return events_count(obs.source) <= 0
  elseif k == 'clock-before' or k == 'clock-before-selected' then
    return runtime_now(rt) < obs.deadline
  elseif k == 'readiness-absent' then
    return not readiness_is_set(obs.source, obs.mode)
  elseif k == 'scalar-unchanged' then
    return (obs.scalar.version or 0) == obs.version
  end
  return true
end

function Resources.prepare_env(rt, env)
  if counters_enabled then count('env.prepare') end
  local flat, err = flatten_env(env, true)
  if not flat then return nil, err end
  local combo = { flat }

  local prepared_resources, reason, derived = Resource.prepare_combo(combo, Proposal.raw_resolved, Proposal.resolve)
  if reason then return nil, reason end

  local effect_set = flat.effects
  if derived then
    effect_set = effect_set and effect_set:copy() or EffectSet.empty()
    local ok, err = effect_set:merge(derived)
    if not ok then return nil, err end
  end

  local prepared_effects
  if effect_set and not effect_set:is_empty() then
    prepared_effects, reason = effect_set:prepare(rt)
    if reason then return nil, reason end
  end
  return { resources = prepared_resources, effects = prepared_effects }
end

function Resources.apply_prepared(prepared)
  if counters_enabled then count('prepared.apply') end
  for i = 1, #(prepared and prepared.resources or {}) do
    Resource.apply_prepared(prepared.resources[i])
  end
end

function Resources.discharge_prepared(rt, prepared)
  if counters_enabled then count('prepared.discharge') end
  for i = 1, #(prepared and prepared.effects or {}) do
    local pc = prepared.effects[i]
    local entry = {
      kind = pc.kind_name or (pc.kind and pc.kind.name) or tostring(pc.kind),
      key = pc.key,
      payload = pc.payload,
    }
    if rt._call_fatal_in_phase then
      rt:_call_fatal_in_phase('effect', 'effect_error', true, function()
        return pc.discharge(rt, entry)
      end)
    else
      pc.discharge(rt, entry)
    end
  end
end

return Resources
