-- Optional low-overhead runtime and proof-search instrumentation.
--
-- Instrumentation is deliberately separate from Runtime.stats.  The latter is
-- a small compatibility counter set which remains available at all times;
-- this module is enabled explicitly with Runtime.new({ instrumentation = ... })
-- and records distributions and slow-plan summaries suitable for performance
-- work.  Ordinary runtimes pay only a nil check at the instrumentation sites.

local Instrumentation = {}
Instrumentation.__index = Instrumentation

local function copy_map(src)
  local out = {}
  for k, v in pairs(src or {}) do out[k] = v end
  return out
end

local function copy_array(src)
  local out = {}
  for i = 1, #(src or {}) do
    local value = src[i]
    if type(value) == 'table' then
      local row = {}
      for k, v in pairs(value) do row[k] = v end
      out[i] = row
    else
      out[i] = value
    end
  end
  return out
end

local function default_clock()
  if os and type(os.clock) == 'function' then return os.clock() end
  return 0
end

local function bucket(value)
  if value == nil then return 'nil' end
  if value <= 0 then return '0' end
  local upper = 1
  while upper < value do upper = upper * 2 end
  if upper == 1 then return '1' end
  return tostring(math.floor(upper / 2) + 1) .. '-' .. tostring(upper)
end

local function normalise_options(opts)
  if opts == true then return {} end
  if type(opts) ~= 'table' then return {} end
  return opts
end

function Instrumentation.new(opts)
  opts = normalise_options(opts)
  local clock = opts.clock
  if type(clock) ~= 'function' then clock = default_clock end
  return setmetatable({
    clock = clock,
    counters = {},
    maxima = {},
    histograms = {},
    slow_plans = {},
    slow_plan_limit = math.max(0, math.floor(opts.slow_plan_limit or 16)),
    trace = opts.trace == true,
    trace_limit = math.max(0, math.floor(opts.trace_limit or 512)),
    state_hash = opts.state_hash == true,
    plan_serial = 0,
  }, Instrumentation)
end

function Instrumentation:inc(name, amount)
  amount = amount or 1
  self.counters[name] = (self.counters[name] or 0) + amount
  return self.counters[name]
end

function Instrumentation:max(name, value)
  local old = self.maxima[name]
  if old == nil or value > old then self.maxima[name] = value end
  return value
end

function Instrumentation:observe(name, value)
  local h = self.histograms[name]
  if not h then h = {}; self.histograms[name] = h end
  local key = bucket(value)
  h[key] = (h[key] or 0) + 1
  return value
end

function Instrumentation:begin_plan(meta)
  self.plan_serial = self.plan_serial + 1
  local plan = {
    id = self.plan_serial,
    started = self.clock(),
    focus = meta and meta.focus,
    pending = meta and meta.pending or 0,
    total_pending = meta and (meta.total_pending or meta.pending) or 0,
    component_size = meta and (meta.component_size or meta.pending) or 0,
    component_dynamic = meta and meta.component_dynamic or 0,
    component_global = meta and meta.component_global == true or false,
    component_edge_visits = meta and meta.component_edge_visits or 0,
    machine = meta and meta.machine,
    search_calls = 0,
    task_steps = 0,
    branches = 0,
    rollbacks = 0,
    rollback_entries = 0,
    trail_entries = 0,
    max_trail = 0,
    max_depth = 1,
    max_active = 0,
    max_intents = 0,
    max_roots = 0,
    max_tasks = 0,
    max_views = 0,
    intent_pairs_scanned = 0,
    compatible_pairs = 0,
    choice_branches = 0,
    preferred_branches = 0,
    fallback_branches = 0,
    witness_alternatives = 0,
    claim_branches = 0,
    claim_all_branches = 0,
    claim_single_branches = 0,
    claim_groups_scanned = 0,
    machine_probes = 0,
    machine_steps = 0,
    max_claim_group = 0,
    recruit_branches = 0,
    exclude_branches = 0,
    footprint_checks = 0,
    footprint_matches = 0,
    footprint_dynamic_matches = 0,
    footprint_exchange_matches = 0,
    footprint_location_matches = 0,
    exchange_domains = 0,
    zero_exchange_domains = 0,
    forced_exchange_opportunities = 0,
    forced_exchanges = 0,
    forced_claim_opportunities = 0,
    forced_claims = 0,
    normalisation_rounds = 0,
    deterministic_steps = 0,
    recruitment_candidates = 0,
    recruitment_best_score = 0,
    states_observed = 0,
    state_duplicates = 0,
    terminal_states_observed = 0,
    terminal_state_duplicates = 0,
    state_seen = self.state_hash and {} or nil,
    events = self.trace and {} or nil,
  }
  self:inc('plans')
  return plan
end

function Instrumentation:event(plan, kind, fields)
  if not self.trace or not plan or not plan.events then return end
  if #plan.events >= self.trace_limit then
    plan.trace_truncated = true
    return
  end
  local event = { kind = kind }
  for k, v in pairs(fields or {}) do event[k] = v end
  plan.events[#plan.events + 1] = event
end


function Instrumentation:observe_state(plan, signature, terminal)
  if not self.state_hash or not plan or not plan.state_seen or not signature then return false end
  plan.states_observed = plan.states_observed + 1
  if terminal then plan.terminal_states_observed = plan.terminal_states_observed + 1 end
  local old = plan.state_seen[signature]
  if old then
    plan.state_duplicates = plan.state_duplicates + 1
    if terminal then plan.terminal_state_duplicates = plan.terminal_state_duplicates + 1 end
    return true
  end
  plan.state_seen[signature] = terminal and 'terminal' or 'branch'
  return false
end

local function insert_slow_plan(self, plan)
  if self.slow_plan_limit <= 0 then return end
  local row = {
    id = plan.id,
    machine = plan.machine,
    focus = plan.focus,
    pending = plan.pending,
    total_pending = plan.total_pending,
    component_size = plan.component_size,
    component_dynamic = plan.component_dynamic,
    component_global = plan.component_global,
    component_edge_visits = plan.component_edge_visits,
    outcome = plan.outcome,
    elapsed = plan.elapsed,
    search_steps = plan.search_steps,
    participants = plan.participants,
    observations = plan.observations,
    writes = plan.writes,
    effects = plan.effects,
    max_depth = plan.max_depth,
    max_intents = plan.max_intents,
    max_roots = plan.max_roots,
    max_tasks = plan.max_tasks,
    max_views = plan.max_views,
    max_trail = plan.max_trail,
    branches = plan.branches,
    rollbacks = plan.rollbacks,
    trail_entries = plan.trail_entries,
    rollback_entries = plan.rollback_entries,
    intent_pairs_scanned = plan.intent_pairs_scanned,
    compatible_pairs = plan.compatible_pairs,
    choice_branches = plan.choice_branches,
    preferred_branches = plan.preferred_branches,
    fallback_branches = plan.fallback_branches,
    witness_alternatives = plan.witness_alternatives,
    claim_branches = plan.claim_branches,
    claim_all_branches = plan.claim_all_branches,
    claim_single_branches = plan.claim_single_branches,
    claim_groups_scanned = plan.claim_groups_scanned,
    machine_probes = plan.machine_probes,
    machine_steps = plan.machine_steps,
    max_claim_group = plan.max_claim_group,
    recruit_branches = plan.recruit_branches,
    exclude_branches = plan.exclude_branches,
    footprint_checks = plan.footprint_checks,
    footprint_matches = plan.footprint_matches,
    footprint_dynamic_matches = plan.footprint_dynamic_matches,
    footprint_exchange_matches = plan.footprint_exchange_matches,
    footprint_location_matches = plan.footprint_location_matches,
    exchange_domains = plan.exchange_domains,
    zero_exchange_domains = plan.zero_exchange_domains,
    forced_exchange_opportunities = plan.forced_exchange_opportunities,
    forced_exchanges = plan.forced_exchanges,
    forced_claim_opportunities = plan.forced_claim_opportunities,
    forced_claims = plan.forced_claims,
    normalisation_rounds = plan.normalisation_rounds,
    deterministic_steps = plan.deterministic_steps,
    recruitment_candidates = plan.recruitment_candidates,
    recruitment_best_score = plan.recruitment_best_score,
    states_observed = plan.states_observed,
    state_duplicates = plan.state_duplicates,
    terminal_states_observed = plan.terminal_states_observed,
    terminal_state_duplicates = plan.terminal_state_duplicates,
    trace_truncated = plan.trace_truncated,
    events = plan.events and copy_array(plan.events) or nil,
  }
  local xs = self.slow_plans
  xs[#xs + 1] = row
  table.sort(xs, function(a, b)
    if a.search_steps ~= b.search_steps then return a.search_steps > b.search_steps end
    return (a.elapsed or 0) > (b.elapsed or 0)
  end)
  while #xs > self.slow_plan_limit do xs[#xs] = nil end
end

function Instrumentation:finish_plan(plan, outcome)
  if not plan then return end
  plan.outcome = outcome or 'retry'
  plan.elapsed = self.clock() - plan.started
  self:inc('plan_' .. plan.outcome)
  self:inc('search_calls', plan.search_calls)
  self:inc('task_steps', plan.task_steps)
  self:inc('branches', plan.branches)
  self:inc('rollbacks', plan.rollbacks)
  self:inc('rollback_entries', plan.rollback_entries)
  self:inc('trail_entries', plan.trail_entries)
  self:inc('intent_pairs_scanned', plan.intent_pairs_scanned)
  self:inc('compatible_pairs', plan.compatible_pairs)
  self:inc('choice_branches', plan.choice_branches)
  self:inc('preferred_branches', plan.preferred_branches)
  self:inc('fallback_branches', plan.fallback_branches)
  self:inc('witness_alternatives', plan.witness_alternatives)
  self:inc('claim_branches', plan.claim_branches)
  self:inc('claim_all_branches', plan.claim_all_branches)
  self:inc('claim_single_branches', plan.claim_single_branches)
  self:inc('claim_groups_scanned', plan.claim_groups_scanned)
  self:inc('machine_probes', plan.machine_probes)
  self:inc('machine_steps', plan.machine_steps)
  self:max('claim_group_size', plan.max_claim_group or 0)
  self:inc('recruit_branches', plan.recruit_branches)
  self:inc('exclude_branches', plan.exclude_branches)
  self:inc('footprint_checks', plan.footprint_checks)
  self:inc('footprint_matches', plan.footprint_matches)
  self:inc('footprint_dynamic_matches', plan.footprint_dynamic_matches)
  self:inc('footprint_exchange_matches', plan.footprint_exchange_matches)
  self:inc('footprint_location_matches', plan.footprint_location_matches)
  self:inc('exchange_domains', plan.exchange_domains)
  self:inc('zero_exchange_domains', plan.zero_exchange_domains)
  self:inc('forced_exchange_opportunities', plan.forced_exchange_opportunities)
  self:inc('forced_exchanges', plan.forced_exchanges)
  self:inc('forced_claim_opportunities', plan.forced_claim_opportunities)
  self:inc('forced_claims', plan.forced_claims)
  self:inc('normalisation_rounds', plan.normalisation_rounds)
  self:inc('deterministic_steps', plan.deterministic_steps)
  self:inc('recruitment_candidates', plan.recruitment_candidates)
  self:max('recruitment_best_score', plan.recruitment_best_score or 0)
  self:inc('states_observed', plan.states_observed)
  self:inc('state_duplicates', plan.state_duplicates)
  self:inc('terminal_states_observed', plan.terminal_states_observed)
  self:inc('terminal_state_duplicates', plan.terminal_state_duplicates)
  self:inc('component_roots_total', plan.component_size or 0)
  self:inc('frontier_roots_total', plan.total_pending or plan.pending or 0)
  self:inc('component_roots_excluded', math.max(0, (plan.total_pending or 0) - (plan.component_size or 0)))
  if plan.component_global then self:inc('component_global_plans') end
  self:max('component_size', plan.component_size or 0)
  self:observe('component_size_per_plan', plan.component_size or 0)
  self:observe('component_fraction_percent', (plan.total_pending or 0) > 0 and ((plan.component_size or 0) * 100 / plan.total_pending) or 0)
  self:observe('exchange_domain_size', plan.max_exchange_domain or 0)
  self:inc('search_cpu_ns', math.floor(plan.elapsed * 1000000000 + 0.5))

  self:max('search_steps_per_plan', plan.search_steps or 0)
  self:max('search_cpu_seconds_per_plan', plan.elapsed or 0)
  self:max('search_depth', plan.max_depth or 1)
  self:max('active_tasks', plan.max_active or 0)
  self:max('intents', plan.max_intents or 0)
  self:max('roots', plan.max_roots or 0)
  self:max('tasks', plan.max_tasks or 0)
  self:max('views', plan.max_views or 0)
  self:max('trail_entries_live', plan.max_trail or 0)

  self:observe('search_steps_per_plan', plan.search_steps or 0)
  self:observe('participants_per_candidate', plan.participants or 0)
  self:observe('intents_per_plan', plan.max_intents or 0)
  self:observe('roots_per_plan', plan.max_roots or 0)
  self:observe('trail_entries_per_plan', plan.trail_entries or 0)
  self:observe('search_cpu_us_per_plan', (plan.elapsed or 0) * 1000000)
  insert_slow_plan(self, plan)
end

function Instrumentation:snapshot()
  local histograms = {}
  for name, values in pairs(self.histograms) do histograms[name] = copy_map(values) end
  return {
    counters = copy_map(self.counters),
    maxima = copy_map(self.maxima),
    histograms = histograms,
    slow_plans = copy_array(self.slow_plans),
  }
end

function Instrumentation:reset()
  self.counters = {}
  self.maxima = {}
  self.histograms = {}
  self.slow_plans = {}
  self.plan_serial = 0
end

return Instrumentation
