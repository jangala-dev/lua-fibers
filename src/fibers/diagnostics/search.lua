-- Optional proof-search instrumentation.
--
-- Metric declarations live in one place. Ordinary runtimes pay only the nil
-- checks at call sites; component profiling and aggregation are owned here.

local Instrumentation = {}
Instrumentation.__index = Instrumentation

local ZERO_FIELDS = {
  'search_calls',
  'task_steps',
  'branches',
  'rollbacks',
  'rollback_entries',
  'trail_entries',
  'trail_set_coalesced',
  'trail_push_coalesced',
  'max_trail',
  'max_active',
  'max_intents',
  'max_roots',
  'max_tasks',
  'max_segments',
  'intent_pairs_scanned',
  'compatible_pairs',
  'choice_branches',
  'choice_alternatives_pruned',
  'opaque_supplier_revelations',
  'dynamic_dependency_refinements',
  'matching_feasibility_failures',
  'binary_relation_failures',
  'matching_guard_revelations',
  'exact_negative_cache_hits',
  'exchange_support_eliminations_learned',
  'exchange_support_eliminations_pruned',
  'supplier_domain_branches',
  'preferred_entries',
  'preferred_states_opened',
  'preferred_state_evidence',
  'preferred_states_closed',
  'fallback_transitions',
  'fallback_dependency_transitions',
  'product_support_closures',
  'witness_alternatives',
  'claim_branches',
  'claim_all_branches',
  'claim_closure_branches',
  'claim_closure_successes',
  'claim_closure_failures',
  'claim_single_branches',
  'claim_groups_scanned',
  'machine_probes',
  'machine_steps',
  'max_claim_group',
  'recruit_branches',
  'exclude_branches',
  'footprint_checks',
  'footprint_matches',
  'footprint_dynamic_matches',
  'footprint_exchange_matches',
  'footprint_location_matches',
  'exchange_domains',
  'zero_exchange_domains',
  'forced_exchange_opportunities',
  'forced_exchanges',
  'forced_claim_opportunities',
  'forced_claims',
  'normalisation_rounds',
  'deterministic_steps',
  'recruitment_candidates',
  'recruitment_best_score',
  'symmetry_exchange_pruned',
}

local MAX_FIELDS = {
  claim_group_size = 'max_claim_group',
  recruitment_best_score = 'recruitment_best_score',
  component_size = 'component_size',
  search_steps_per_plan = 'search_steps',
  search_cpu_seconds_per_plan = 'elapsed',
  search_depth = 'max_depth',
  active_tasks = 'max_active',
  intents = 'max_intents',
  roots = 'max_roots',
  tasks = 'max_tasks',
  segments = 'max_segments',
  trail_entries_live = 'max_trail',
}

local SUM_FIELDS = {
  'option_nodes',
  'option_dynamic_roots',
  'option_external_roots',
  'dependency_locations',
  'dependency_resources',
  'dependency_exchanges',
}

local NOT_SUMMED = {}
for _, field in pairs(MAX_FIELDS) do
  NOT_SUMMED[field] = true
end
for i = 1, #ZERO_FIELDS do
  local field = ZERO_FIELDS[i]
  if not NOT_SUMMED[field] then
    SUM_FIELDS[#SUM_FIELDS + 1] = field
  end
end

local HISTOGRAM_FIELDS = {
  component_size_per_plan = 'component_size',
  exchange_domain_size = 'max_exchange_domain',
  search_steps_per_plan = 'search_steps',
  participants_per_candidate = 'participants',
  intents_per_plan = 'max_intents',
  roots_per_plan = 'max_roots',
  trail_entries_per_plan = 'trail_entries',
  option_nodes_per_plan = 'option_nodes',
  dependency_locations_per_plan = 'dependency_locations',
  dependency_resources_per_plan = 'dependency_resources',
  dependency_exchanges_per_plan = 'dependency_exchanges',
}

local function copy_map(source)
  local out = {}
  for key, value in pairs(source or {}) do
    out[key] = value
  end
  return out
end

local function copy_array(source)
  local out = {}
  for i = 1, #(source or {}) do
    local value = source[i]
    out[i] = type(value) == 'table' and copy_map(value) or value
  end
  return out
end

local function default_clock()
  return os and type(os.clock) == 'function' and os.clock() or 0
end

local function histogram_bucket(value)
  if value == nil then
    return 'nil'
  end
  if value <= 0 then
    return '0'
  end
  local upper = 1
  while upper < value do
    upper = upper * 2
  end
  if upper == 1 then
    return '1'
  end
  return tostring(math.floor(upper / 2) + 1) .. '-' .. tostring(upper)
end

local function map_count(values)
  local count = 0
  for _ in pairs(values or {}) do
    count = count + 1
  end
  return count
end

local function component_shape(requests, component)
  local shape = {
    option_nodes = 0,
    option_dynamic_roots = 0,
    option_external_roots = 0,
    option_node_kinds = {},
    request_summaries = {},
  }
  local locations, resources, exchanges = {}, {}, {}
  local function add(request)
    local metadata = request and request.metadata
    if not metadata then
      return
    end
    shape.request_summaries[#shape.request_summaries + 1] = {
      id = request.id,
      name = request.name,
      dynamic = metadata.dynamic == true,
      external = metadata.external == true,
      nodes = metadata.nodes or 0,
      kinds = metadata.node_kinds,
    }
    shape.option_nodes = shape.option_nodes + (metadata.nodes or 0)
    if metadata.dynamic then
      shape.option_dynamic_roots = shape.option_dynamic_roots + 1
    end
    if metadata.external then
      shape.option_external_roots = shape.option_external_roots + 1
    end
    for kind, count in pairs(metadata.node_kinds or {}) do
      shape.option_node_kinds[kind] = (shape.option_node_kinds[kind] or 0) + count
    end
    for value in pairs(metadata.locations or {}) do
      locations[value] = true
    end
    for value in pairs(metadata.resources or {}) do
      resources[value] = true
    end
    for value in pairs(metadata.exchanges or {}) do
      exchanges[value] = true
    end
  end
  local ids = component and component.ids
  if ids then
    for i = 1, #ids do
      add(requests[ids[i]])
    end
  else
    for _, request in pairs(requests) do
      add(request)
    end
  end
  shape.dependency_locations = map_count(locations)
  shape.dependency_resources = map_count(resources)
  shape.dependency_exchanges = map_count(exchanges)
  return shape
end

local function normalise_options(options)
  return options == true and {} or type(options) == 'table' and options or {}
end

function Instrumentation.new(options)
  options = normalise_options(options)
  return setmetatable({
    clock = type(options.clock) == 'function' and options.clock or default_clock,
    counters = {},
    maxima = {},
    histograms = {},
    slow_plans = {},
    slow_plan_limit = math.max(0, math.floor(options.slow_plan_limit or 16)),
    trace = options.trace == true,
    trace_limit = math.max(0, math.floor(options.trace_limit or 512)),
    plan_serial = 0,
  }, Instrumentation)
end

function Instrumentation:inc(name, amount)
  self.counters[name] = (self.counters[name] or 0) + (amount or 1)
  return self.counters[name]
end

function Instrumentation:max(name, value)
  local old = self.maxima[name]
  if old == nil or value > old then
    self.maxima[name] = value
  end
  return value
end

function Instrumentation:observe(name, value)
  local histogram = self.histograms[name]
  if not histogram then
    histogram = {}
    self.histograms[name] = histogram
  end
  local key = histogram_bucket(value)
  histogram[key] = (histogram[key] or 0) + 1
  return value
end

function Instrumentation:begin_plan(meta)
  meta = meta or {}
  self.plan_serial = self.plan_serial + 1
  local plan = {
    id = self.plan_serial,
    started = self.clock(),
    focus = meta.focus,
    pending = meta.pending or 0,
    total_pending = meta.total_pending or meta.pending or 0,
    component_size = meta.component_size or meta.pending or 0,
    component_dynamic = meta.component_dynamic or 0,
    component_global = meta.component_global == true,
    component_edge_visits = meta.component_edge_visits or 0,
    option_nodes = meta.option_nodes or 0,
    option_dynamic_roots = meta.option_dynamic_roots or 0,
    option_external_roots = meta.option_external_roots or 0,
    dependency_locations = meta.dependency_locations or 0,
    dependency_resources = meta.dependency_resources or 0,
    dependency_exchanges = meta.dependency_exchanges or 0,
    option_node_kinds = copy_map(meta.option_node_kinds),
    request_summaries = meta.request_summaries and copy_array(meta.request_summaries) or nil,
    machine = meta.machine,
    max_depth = 1,
    events = self.trace and {} or nil,
  }
  for i = 1, #ZERO_FIELDS do
    plan[ZERO_FIELDS[i]] = 0
  end
  self:inc('plans')
  return plan
end

function Instrumentation:begin_search_plan(runtime, requests, focus, component)
  local pending = map_count(requests)
  local shape = component_shape(requests, component)
  shape.focus = focus
  shape.pending = pending
  shape.machine = runtime.machine_name or 'ledger'
  shape.total_pending = component and component.total or pending
  shape.component_size = component and component.size or pending
  shape.component_dynamic = component and component.dynamic or 0
  shape.component_global = component and component.global == true or false
  shape.component_edge_visits = component and component.edge_visits or 0
  return self:begin_plan(shape)
end

function Instrumentation:event(plan, kind, fields)
  if not self.trace or not plan or not plan.events then
    return
  end
  if #plan.events >= self.trace_limit then
    plan.trace_truncated = true
    return
  end
  local event = { kind = kind }
  for key, value in pairs(fields or {}) do
    event[key] = value
  end
  plan.events[#plan.events + 1] = event
end

local function plan_copy(plan)
  local row = {}
  for key, value in pairs(plan) do
    if key ~= 'started' then
      if key == 'option_node_kinds' then
        row[key] = copy_map(value)
      elseif key == 'request_summaries' or key == 'events' then
        row[key] = copy_array(value)
      else
        row[key] = value
      end
    end
  end
  return row
end

local function retain_slow_plan(self, plan)
  if self.slow_plan_limit <= 0 then
    return
  end
  local plans = self.slow_plans
  plans[#plans + 1] = plan_copy(plan)
  table.sort(plans, function(left, right)
    if left.search_steps ~= right.search_steps then
      return left.search_steps > right.search_steps
    end
    return (left.elapsed or 0) > (right.elapsed or 0)
  end)
  while #plans > self.slow_plan_limit do
    plans[#plans] = nil
  end
end

function Instrumentation:finish_plan(plan, outcome)
  if not plan then
    return
  end
  plan.outcome = outcome or 'retry'
  plan.elapsed = self.clock() - plan.started
  self:inc('plan_' .. plan.outcome)
  for i = 1, #SUM_FIELDS do
    local field = SUM_FIELDS[i]
    self:inc(field, plan[field] or 0)
  end
  for kind, count in pairs(plan.option_node_kinds or {}) do
    self:inc('option_kind_' .. tostring(kind), count)
  end
  for name, field in pairs(MAX_FIELDS) do
    self:max(name, plan[field] or 0)
  end
  for name, field in pairs(HISTOGRAM_FIELDS) do
    self:observe(name, plan[field] or 0)
  end

  local total = plan.total_pending or 0
  self:inc('component_roots_total', plan.component_size or 0)
  self:inc('frontier_roots_total', total)
  self:inc('component_roots_excluded', math.max(0, total - (plan.component_size or 0)))
  if plan.component_global then
    self:inc('component_global_plans')
  end
  self:observe('component_fraction_percent', total > 0 and (plan.component_size or 0) * 100 / total or 0)
  self:inc('search_cpu_ns', math.floor(plan.elapsed * 1000000000 + 0.5))
  self:observe('search_cpu_us_per_plan', plan.elapsed * 1000000)
  retain_slow_plan(self, plan)
end

function Instrumentation:report()
  local histograms = {}
  for name, values in pairs(self.histograms) do
    histograms[name] = copy_map(values)
  end
  return {
    counters = copy_map(self.counters),
    maxima = copy_map(self.maxima),
    histograms = histograms,
    slow_plans = copy_array(self.slow_plans),
  }
end

function Instrumentation:reset()
  self.counters, self.maxima, self.histograms, self.slow_plans = {}, {}, {}, {}
  self.plan_serial = 0
end

return Instrumentation
