-- This module is the boundary between the algebraic transaction search and the
-- mutable/external world.  Resource kinds own their local frontier protocol:
-- clone/merge/project/prepare/apply for committed deltas, plus optional leaf
-- miss certification.  The transaction net owns operation algebra; resource
-- kinds only certify local mutable facts.

local Op = require('fibers.base.op')
local Wait = require('fibers.kernel.wait')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local EffectSet = require('fibers.kernel.effect.set')
local FrontierKit = require('fibers.kernel.frontier')

local Resources = {}

local clock_frontiers = setmetatable({}, { __mode = 'k' })
local runtime_now

local pack_ = Op._pack
local unpack_ = Op._unpack

local function append(out, item) out[#out + 1] = item end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function append_list(dst, src)
  for i = 1, #(src or {}) do dst[#dst + 1] = src[i] end
end

local function map_key(a, b)
  if b == nil then return tostring(a) end
  return tostring(a) .. ':' .. tostring(b)
end

local function ensure_frontier_table(obj)
  local t = obj and rawget(obj, '_fibers_frontiers')
  if not t and obj then
    t = {}
    rawset(obj, '_fibers_frontiers', t)
  end
  return t
end

local function ensure_named_frontier(obj, name)
  if obj == nil then return nil end
  local t = ensure_frontier_table(obj)
  local f = t[name]
  if not f then
    f = FrontierKit.Frontier.new((obj._fibers_id or obj.name or tostring(obj)) .. ':' .. tostring(name))
    t[name] = f
  end
  return f
end

local function maybe_named_frontier(obj, name)
  local t = obj and rawget(obj, '_fibers_frontiers')
  return t and t[name] or nil
end

local function frontier_name_for_source(source, kind, key)
  if not source then return nil end
  if source.kind == 'signal' then
    return kind or 'signal.state'
  elseif source.kind == 'queue' then
    if kind == 'queue.item' then return 'queue.item:' .. tostring(key) end
    return kind or 'queue.state'
  elseif source.kind == 'readiness' then
    local mode = key or kind or source.mode or 'read'
    if kind == 'readiness' and key ~= nil then mode = key end
    return 'readiness:' .. tostring(mode)
  elseif source.kind == 'clock' then
    return 'clock:' .. tostring(kind or 'state') .. ':' .. tostring(key or '')
  end
  return kind or 'source.state'
end

local function add_frontier_to_env(env, frontier)
  if not env or not frontier or not env.collect_frontiers then return end
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

function Resources.new_env(parent, collect_frontiers, collect_observations)
  if collect_frontiers == nil and parent then collect_frontiers = parent.collect_frontiers end
  if collect_observations == nil and parent then collect_observations = parent.collect_observations end
  return {
    res = nil,
    res_list = nil,
    effects = nil,
    selected = {},
    lost = {},
    observations = {},
    absence_observations = {},
    frontiers = {},
    frontier_seen = {},
    collect_frontiers = collect_frontiers == true,
    collect_observations = collect_observations == true,
    has_absence = false,
    parent = parent,
  }
end

function Resources.copy_env(env)
  if not env then return Resources.new_env() end
  local out = Resources.new_env(env.parent and Resources.copy_env(env.parent) or nil, env.collect_frontiers, env.collect_observations)
  Resource.copy_from(out, env)
  out.effects = copy_effects(env.effects)
  out.selected = copy_list(env.selected)
  out.lost = copy_list(env.lost)
  out.observations = copy_list(env.observations)
  out.absence_observations = copy_list(env.absence_observations)
  out.frontiers = copy_list(env.frontiers)
  out.frontier_seen = {}
  for i = 1, #(out.frontiers or {}) do out.frontier_seen[out.frontiers[i]] = true end
  out.has_absence = env.has_absence or false
  return out
end

function Resources.lane_env_from(parent)
  return Resources.new_env(parent)
end

local function copy_without_parent(env)
  local out = Resources.new_env(nil, env.collect_frontiers, env.collect_observations)
  Resource.copy_from(out, env)
  out.effects = copy_effects(env.effects)
  out.selected = copy_list(env.selected)
  out.lost = copy_list(env.lost)
  out.observations = copy_list(env.observations)
  out.absence_observations = copy_list(env.absence_observations)
  out.frontiers = copy_list(env.frontiers)
  out.frontier_seen = {}
  for i = 1, #(out.frontiers or {}) do out.frontier_seen[out.frontiers[i]] = true end
  out.has_absence = env.has_absence or false
  return out
end

function Resources.copy_delta(env)
  if not env then return Resources.new_env() end
  return copy_without_parent(env)
end

function Resources.overlay_for_env(env)
  if not env then return nil end
  local acc = { res = nil, res_list = nil }
  local function merge(e)
    if not e then return true end
    if e.parent then merge(e.parent) end
    Resource.merge_seq_into(acc, e)
    return true
  end
  merge(env)
  if not acc.res_list then return nil end
  return acc
end

local function merge_effect_sets_seq(dst, src)
  if not src then return true end
  dst.effects = dst.effects or EffectSet.empty()
  local ok, err = dst.effects:merge(src)
  if not ok then return false, err end
  return true
end

function Resources.merge_seq_into(dst, src)
  if src.parent then src = copy_without_parent(src) end
  local ok, err = Resource.merge_seq_into(dst, src)
  if not ok then return false, err end
  ok, err = merge_effect_sets_seq(dst, src.effects)
  if not ok then return false, err end
  append_list(dst.selected, src.selected)
  append_list(dst.lost, src.lost)
  append_list(dst.observations, src.observations)
  append_list(dst.absence_observations, src.absence_observations)
  for i = 1, #(src.frontiers or {}) do add_frontier_to_env(dst, src.frontiers[i]) end
  if src.has_absence then dst.has_absence = true end
  return true
end

function Resources.merge_parallel_into(dst, src)
  if src.parent then src = copy_without_parent(src) end
  local ok, err = Resource.merge_parallel_into(dst, src)
  if not ok then return false, err end
  ok, err = merge_effect_sets_seq(dst, src.effects)
  if not ok then return false, err end
  append_list(dst.selected, src.selected)
  append_list(dst.lost, src.lost)
  append_list(dst.observations, src.observations)
  append_list(dst.absence_observations, src.absence_observations)
  for i = 1, #(src.frontiers or {}) do add_frontier_to_env(dst, src.frontiers[i]) end
  if src.has_absence then dst.has_absence = true end
  return true
end

function Resources.merge_lanes(parent, lanes)
  local lane_acc = Resources.new_env(nil, parent and parent.collect_frontiers, parent and parent.collect_observations)
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

function Resources.add_selected(env, item) env.selected[#env.selected + 1] = item end
function Resources.add_lost(env, item) env.lost[#env.lost + 1] = item end
function Resources.add_frontier(env, frontier)
  add_frontier_to_env(env, frontier)
end

function Resources.add_observation(env, obs)
  if env.collect_observations then env.observations[#env.observations + 1] = obs end
  add_frontier_to_env(env, obs_frontier(obs))
end

function Resources.add_absence_observations(env, observations)
  for i = 1, #(observations or {}) do
    local obs = observations[i]
    if env.collect_observations then env.absence_observations[#env.absence_observations + 1] = obs end
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

function Resources.object_frontier(obj)
  return ensure_named_frontier(obj, 'version')
end

function Resources.source_frontier(source, kind, key)
  return ensure_named_frontier(source, frontier_name_for_source(source, kind, key))
end

function Resources.clock_before_frontier(source, deadline)
  local f = ensure_named_frontier(source, frontier_name_for_source(source, 'clock-before', deadline))
  if f and source ~= nil then
    local t = clock_frontiers[source]
    if not t then t = {}; clock_frontiers[source] = t end
    t[deadline] = f
  end
  return f
end

function Resources.invalidate_matured_clock_frontiers(rt)
  local now = runtime_now(rt)
  for _source, entries in pairs(clock_frontiers) do
    for deadline, frontier in pairs(entries) do
      if now >= deadline then
        entries[deadline] = nil
        frontier:invalidate('clock deadline reached')
      end
    end
  end
end

function Resources.observe_frontier(ctx, frontier, env)
  if not frontier then return nil end
  if ctx and (ctx.collect_frontiers or ctx.observer) then add_frontier_to_env(env, frontier) end
  if ctx and ctx.observer then frontier:observe(ctx.observer) end
  return frontier.gen
end

function Resources.invalidate_object(obj, reason)
  local f = maybe_named_frontier(obj, 'version')
  if f then f:invalidate(reason) end
end

function Resources.invalidate_source(source, kind, key, reason)
  local f = maybe_named_frontier(source, frontier_name_for_source(source, kind, key))
  if f then f:invalidate(reason) end
end

function Resources.invalidate_source_all(source, reason)
  local t = rawget(source or {}, '_fibers_frontiers')
  if not t then return end
  for _name, f in pairs(t) do f:invalidate(reason) end
end

local function source_version(src) return (src and src.version) or 0 end
local function object_version(obj) return (obj and (obj.version or obj.owner_version)) or 0 end

runtime_now = function(rt)
  if rt and rt.now then return rt:now() end
  local host = rt and rt.host or nil
  if host and host.now then return host.now(rt) end
  return 0
end

local function normalise_readiness_mode(source, mode)
  mode = mode or (source and source.mode) or 'read'
  if mode == 'wr' then mode = 'write' end
  return mode
end

local function readiness_is_set(source, mode)
  mode = normalise_readiness_mode(source, mode)
  if type(source.ready) == 'table' then return source.ready[mode] == true end
  return source.ready == true and mode == normalise_readiness_mode(source, source.mode)
end

local function queue_count(source)
  local head, tail = source.head or 1, source.tail or 0
  local n = tail - head + 1
  return n > 0 and n or 0
end

local function queue_head(source)
  if queue_count(source) <= 0 then return nil end
  return source.queue and source.queue[source.head or 1] or nil
end

local function primitive_resource(op)
  if type(op) ~= 'table' or op.kind ~= 'prim' or op.prim ~= 'resource' then return nil end
  return op.resource, op.resource_kind, op.payload or {}
end

function Resources.channel_leaf(op)
  local resource, kind, payload = primitive_resource(op)
  if kind and kind.name == 'channel' then
    if payload.op == 'get' then return 'get', resource, nil end
    if payload.op == 'put' then return 'put', resource, payload.value end
  end
  return nil
end

local function make_resource_ctx(st, task)
  local ctx = {
    rt = st.rt,
    overlay = Resources.overlay_for_env(task.env),
    origin = task.root_id,
    observer = st.observer,
    collect_frontiers = st.collect_frontiers,
  }
  function ctx:observe_frontier(frontier)
    Resources.observe_frontier(self, frontier, task.env)
    return frontier and frontier.gen or nil
  end
  function ctx:observe_version(obj)
    local v = object_version(obj)
    if not (self.collect_frontiers or self.observer or task.env.collect_observations) then return v end
    local frontier = Resources.object_frontier(obj)
    Resources.observe_frontier(self, frontier, task.env)
    Resources.add_observation(task.env, { kind = 'version', object = obj, version = v, frontier = frontier })
    return v
  end
  function ctx:before(source, deadline)
    if deadline == nil then deadline, source = source, nil end
    if not (self.collect_frontiers or self.observer or task.env.collect_observations) then return deadline end
    local frontier = Resources.clock_before_frontier(source, deadline)
    Resources.observe_frontier(self, frontier, task.env)
    Resources.add_observation(task.env, { kind = 'clock-before-selected', source = source, deadline = deadline, observed_now = runtime_now(st.rt), frontier = frontier })
    return deadline
  end
  function ctx:now() return runtime_now(st.rt) end
  return ctx
end

local function commit_candidate_into_env(env, c)
  local ok, err = Resource.merge_seq_into(env, c)
  if not ok then return false, err end
  if c.effects then
    env.effects = env.effects or EffectSet.empty()
    ok, err = env.effects:merge(c.effects)
    if not ok then return false, err end
  end
  append_list(env.selected, c.selected_nacks)
  append_list(env.lost, c.lost_nacks)
  return true
end

function Resources.apply(st, task, op, complete_task, new_result)
  if op.kind == 'emit' then
    local ok, err = Resources.add_effect(task.env, op.effect)
    if not ok then st:set_unknown(nil, err or 'effect-conflict') else complete_task(st, task, new_result(pack_(true))) end
    return true
  end

  local resource, kind, payload = primitive_resource(op)
  if not resource then return false end
  if kind and kind.name == 'channel' then return false end
  local eval = kind and kind.eval
  if not eval then error('resource primitive requires kind.eval', 2) end

  local ctx = make_resource_ctx(st, task)
  local r = Result.from(eval(resource, payload, ctx))
  if r.status == 'wait' or r.status ~= 'ready' then
    local cert = {}
    if Resources.absence_leaf(st.rt, op, cert, st.observer, st.collect_frontiers) then
      st:set_miss(cert, r.status == 'wait' and { r.wait } or nil)
    else
      st:set_unknown(r.status == 'wait' and { r.wait } or nil, 'resource-blocked')
    end
    return true
  end

  local c = r.proposal
  local ok, err = commit_candidate_into_env(task.env, c)
  if not ok then st:set_unknown(nil, err or 'resource-conflict'); return true end
  local vals = Proposal.resolve_pack(c.vals, c.subst)
  complete_task(st, task, new_result(vals))
  return true
end

local function absence_ctx(rt, out, observer, collect_frontiers)
  local ctx = { rt = rt, observer = observer, collect_frontiers = collect_frontiers == true }
  function ctx:observe_frontier(frontier)
    if frontier and self.observer then frontier:observe(self.observer) end
    return frontier and frontier.gen or nil
  end
  function ctx:observe_version(obj, label)
    if obj ~= nil then
      local frontier
      if self.observer or self.collect_frontiers then frontier = Resources.object_frontier(obj) end
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

function Resources.absence_leaf(rt, op, out, observer, collect_frontiers)
  local want_frontier = observer ~= nil or collect_frontiers == true
  local resource, kind, payload = primitive_resource(op)
  if not resource or not kind then return false end

  if kind.name == 'channel' then
    local f = want_frontier and Resources.object_frontier(resource) or nil
    if f and observer then f:observe(observer) end
    append(out, { kind = 'channel-absent', channel = resource, role = payload and payload.op, frontier = f })
    return true
  end

  if type(kind.absence) == 'function' then
    local before = #out
    local ok = kind.absence(resource, payload or {}, absence_ctx(rt, out, observer, collect_frontiers))
    if ok or #out > before then return true end
  end

  if kind.name == 'source' then
    if resource.kind == 'signal' and payload.op == 'wait' and not resource.ready then
      local f = want_frontier and Resources.source_frontier(resource, 'signal.state') or nil; if f and observer then f:observe(observer) end; append(out, { kind = 'signal-absent', source = resource, version = source_version(resource), frontier = f }); return true
    elseif resource.kind == 'queue' and payload.op == 'next' and queue_count(resource) <= 0 then
      local f = want_frontier and Resources.source_frontier(resource, 'queue.empty') or nil; if f and observer then f:observe(observer) end; append(out, { kind = 'queue-empty', source = resource, version = source_version(resource), frontier = f }); return true
    elseif resource.kind == 'clock' and payload.op == 'until' and runtime_now(rt) < payload.deadline then
      local f = want_frontier and Resources.clock_before_frontier(resource, payload.deadline) or nil; if f and observer then f:observe(observer) end; append(out, { kind = 'clock-before', source = resource, deadline = payload.deadline, frontier = f }); return true
    elseif resource.kind == 'readiness' and payload.op == 'wait' then
      local mode = normalise_readiness_mode(resource, payload.mode or resource.mode)
      if not readiness_is_set(resource, mode) then local f = want_frontier and Resources.source_frontier(resource, 'readiness', mode) or nil; if f and observer then f:observe(observer) end; append(out, { kind = 'readiness-absent', source = resource, mode = mode, version = source_version(resource), frontier = f }); return true end
    end
  elseif kind.name == 'cell' and payload.op == 'changed' then
    local version = resource.version or 0
    if version == payload.version then local f = want_frontier and Resources.object_frontier(resource) or nil; if f and observer then f:observe(observer) end; append(out, { kind = 'cell-unchanged', cell = resource, version = version, frontier = f }); return true end
  end
  return false
end

function Resources.validate_observation(rt, obs)
  local k = obs.kind
  if k == 'version' then
    return object_version(obs.object) == obs.version
  elseif k == 'signal-absent' then
    return (not obs.source.ready) and source_version(obs.source) == obs.version
  elseif k == 'queue-empty' then
    return queue_count(obs.source) <= 0 and source_version(obs.source) == obs.version
  elseif k == 'clock-before' then
    return runtime_now(rt) < obs.deadline
  elseif k == 'clock-before-selected' then
    return runtime_now(rt) < obs.deadline
  elseif k == 'readiness-absent' then
    return (not readiness_is_set(obs.source, obs.mode)) and source_version(obs.source) == obs.version
  elseif k == 'cell-unchanged' then
    return (obs.cell.version or 0) == obs.version
  end
  return true
end

function Resources.prepare_env(rt, env)
  local prepared_resources, reason, derived = Resource.prepare_combo({ env }, Proposal.raw_resolved, Proposal.resolve)
  if reason then return nil, reason end

  local effect_set = env.effects
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
  for i = 1, #(prepared and prepared.resources or {}) do
    Resource.apply_prepared(prepared.resources[i])
  end
end

function Resources.discharge_prepared(rt, prepared)
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
