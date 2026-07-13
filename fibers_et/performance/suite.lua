-- Tiered validating performance suite for fibers.
--
-- Headline timings are collected with optional instrumentation disabled.  Each
-- case is then run once with diagnostics enabled, so proof-search statistics do
-- not contaminate the throughput samples they are intended to explain.

local function join_path(prefix, suffix)
  if prefix == '' then
    return suffix
  end
  return prefix .. suffix
end

local argv0 = (arg and arg[0]) or ''
local here = argv0:match('^(.*[/\\])[^/\\]*$') or ''
local root = here:gsub('performance[/\\]$', '')
package.path = table.concat({
  join_path(root, '?.lua'),
  join_path(root, '?/init.lua'),
  join_path(root, '?/?.lua'),
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  '../?.lua',
  '../?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.kernel.runtime')
local Clock = require('performance.clock')
local cases = require('performance.cases')

local function env(name, default)
  local value = os.getenv(name)
  if value == nil or value == '' then
    return default
  end
  return value
end

local function env_number(name, default)
  local value = tonumber(env(name, ''))
  if value == nil then
    return default
  end
  return value
end

local scale = math.max(0.01, env_number('FIBERS_PERF_SCALE', 1))
local repeats = math.max(1, math.floor(env_number('FIBERS_PERF_REPEATS', 3)))
local warmup = env_number('FIBERS_PERF_WARMUP', 1) ~= 0
local tiers_text = env('FIBERS_PERF_TIERS', 'simple,moderate')
local case_filter = env('FIBERS_PERF_CASE', arg and arg[1] or '')
local format = env('FIBERS_PERF_FORMAT', 'text')
local output_path = env('FIBERS_PERF_OUTPUT', '')
local machine = env('FIBERS_PERF_MACHINE', 'trail')
local choice_seed = math.floor(env_number('FIBERS_PERF_SEED', 1))
local diagnostics = env_number('FIBERS_PERF_DIAGNOSTICS', 1) ~= 0
local trace = env_number('FIBERS_PERF_TRACE', 0) ~= 0
local state_hash = env_number('FIBERS_PERF_STATE_HASH', 1) ~= 0
local slow_plan_limit = math.max(1, math.floor(env_number('FIBERS_PERF_SLOW_PLANS', 8)))
local advanced_profile = env('FIBERS_PERF_ADVANCED', 'full')

local function apply_advanced_profile(opts)
  if advanced_profile == 'off' or advanced_profile == 'baseline' then
    opts.refutation_cache = false
    opts.state_memoization = false
    opts.certified_symmetry = false
    opts.plan_reuse = false
  elseif advanced_profile ~= 'full' then
    error('FIBERS_PERF_ADVANCED must be full or off')
  end
  return opts
end

local selected_tiers = {}
for tier in string.gmatch(tiers_text, '[^,%s]+') do
  selected_tiers[tier] = true
end
if tiers_text == 'all' then
  selected_tiers = { simple = true, moderate = true, complex = true }
end

local function median(values)
  table.sort(values)
  local n = #values
  if n % 2 == 1 then
    return values[(n + 1) / 2]
  end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

local function min_value(values)
  local out = values[1]
  for i = 2, #values do
    if values[i] < out then
      out = values[i]
    end
  end
  return out
end

local function max_value(values)
  local out = values[1]
  for i = 2, #values do
    if values[i] > out then
      out = values[i]
    end
  end
  return out
end

local function bucket_upper(label)
  if label == nil or label == 'nil' then
    return 0
  end
  local upper = tostring(label):match('%-(%d+)$') or tostring(label):match('^(%d+)$')
  return tonumber(upper) or 0
end

local function histogram_quantile_upper(histogram, quantile)
  if type(histogram) ~= 'table' then
    return 0
  end
  local buckets, total = {}, 0
  for label, count in pairs(histogram) do
    local n = tonumber(count) or 0
    buckets[#buckets + 1] = { upper = bucket_upper(label), count = n }
    total = total + n
  end
  if total == 0 then
    return 0
  end
  table.sort(buckets, function(a, b)
    return a.upper < b.upper
  end)
  local target, seen = math.max(1, math.ceil(total * quantile)), 0
  for i = 1, #buckets do
    seen = seen + buckets[i].count
    if seen >= target then
      return buckets[i].upper
    end
  end
  return buckets[#buckets].upper
end

local function case_matches(case)
  if not selected_tiers[case.tier] then
    return false
  end
  if case_filter == '' then
    return true
  end
  local key = case.tier .. '/' .. case.group .. '/' .. case.name
  return key:find(case_filter, 1, true) ~= nil
    or case.group:find(case_filter, 1, true) ~= nil
    or case.name:find(case_filter, 1, true) ~= nil
end

local Context = {}
Context.__index = Context

function Context.new(instrumented)
  return setmetatable({ instrumented = instrumented, runtimes = {} }, Context)
end

function Context:instrumentation_options()
  if not self.instrumented then
    return nil
  end
  return {
    trace = trace,
    trace_limit = 512,
    slow_plan_limit = slow_plan_limit,
    clock = Clock.now,
    state_hash = state_hash,
  }
end

function Context:runtime(opts)
  opts = opts or {}
  local rt_opts = {}
  for k, v in pairs(opts) do
    rt_opts[k] = v
  end
  rt_opts.machine = rt_opts.machine or machine
  rt_opts.choice_seed = rt_opts.choice_seed or choice_seed
  rt_opts.instrumentation = self:instrumentation_options()
  apply_advanced_profile(rt_opts)
  local rt = Runtime.new(rt_opts)
  self.runtimes[#self.runtimes + 1] = rt
  return rt
end

function Context:run_options(opts)
  local out = {}
  for k, v in pairs(opts or {}) do
    out[k] = v
  end
  out.machine = out.machine or machine
  out.choice_seed = out.choice_seed or choice_seed
  out.instrumentation = self:instrumentation_options()
  return apply_advanced_profile(out)
end

function Context:add_runtime(rt)
  if not rt then
    return
  end
  for i = 1, #self.runtimes do
    if self.runtimes[i] == rt then
      return
    end
  end
  self.runtimes[#self.runtimes + 1] = rt
end

local function merge_snapshot(dst, src)
  if not src then
    return dst
  end
  dst = dst or { counters = {}, maxima = {}, histograms = {}, slow_plans = {} }
  for k, v in pairs(src.counters or {}) do
    dst.counters[k] = (dst.counters[k] or 0) + v
  end
  for k, v in pairs(src.maxima or {}) do
    if dst.maxima[k] == nil or v > dst.maxima[k] then
      dst.maxima[k] = v
    end
  end
  for name, histogram in pairs(src.histograms or {}) do
    local target = dst.histograms[name]
    if not target then
      target = {}
      dst.histograms[name] = target
    end
    for bucket, count in pairs(histogram) do
      target[bucket] = (target[bucket] or 0) + count
    end
  end
  for i = 1, #(src.slow_plans or {}) do
    dst.slow_plans[#dst.slow_plans + 1] = src.slow_plans[i]
  end
  table.sort(dst.slow_plans, function(a, b)
    if (a.search_steps or 0) ~= (b.search_steps or 0) then
      return (a.search_steps or 0) > (b.search_steps or 0)
    end
    return (a.elapsed or 0) > (b.elapsed or 0)
  end)
  while #dst.slow_plans > slow_plan_limit do
    dst.slow_plans[#dst.slow_plans] = nil
  end
  return dst
end

function Context:snapshot()
  local out
  for i = 1, #self.runtimes do
    out = merge_snapshot(out, self.runtimes[i]:instrumentation_snapshot())
  end
  return out or { counters = {}, maxima = {}, histograms = {}, slow_plans = {} }
end

local function run_once(case, n, instrumented)
  collectgarbage('collect')
  local before_kb = collectgarbage('count')
  local ctx = Context.new(instrumented)
  local started = Clock.now()
  local operations = case.run(ctx, n)
  local elapsed = Clock.now() - started
  collectgarbage('collect')
  local after_kb = collectgarbage('count')
  return {
    elapsed = elapsed,
    operations = operations or n,
    retained_kb = after_kb - before_kb,
    diagnostics = instrumented and ctx:snapshot() or nil,
  }
end

local results = {}
for _, case in ipairs(cases) do
  if case_matches(case) then
    local n = math.max(1, math.floor(case.iterations * scale))
    if warmup and n >= 20 then
      run_once(case, math.max(1, math.floor(n / 20)), false)
    end
    local samples, retained = {}, {}
    local operations
    for _ = 1, repeats do
      local run = run_once(case, n, false)
      samples[#samples + 1] = run.elapsed
      retained[#retained + 1] = run.retained_kb
      operations = run.operations
    end
    local diagnostic_run = diagnostics and run_once(case, n, true) or nil
    local diag = diagnostic_run and diagnostic_run.diagnostics or nil
    local counters = diag and diag.counters or {}
    local maxima = diag and diag.maxima or {}
    local request_total = (counters.requests_dynamic or 0) + (counters.requests_analysable or 0)
    results[#results + 1] = {
      tier = case.tier,
      group = case.group,
      name = case.name,
      iterations = n,
      operations = operations or n,
      samples = samples,
      median_seconds = median(samples),
      min_seconds = min_value(samples),
      max_seconds = max_value(samples),
      median_us_per_op = median(samples) * 1000000 / (operations or n),
      median_retained_kb = median(retained),
      diagnostic_seconds = diagnostic_run and diagnostic_run.elapsed or nil,
      diagnostics = diag,
      search_calls_per_plan = (counters.plans or 0) > 0
          and (counters.search_calls or 0) / counters.plans
        or 0,
      branches_per_plan = (counters.plans or 0) > 0 and (counters.branches or 0) / counters.plans
        or 0,
      p50_search_steps_upper = histogram_quantile_upper(
        diag and diag.histograms.search_steps_per_plan,
        0.50
      ),
      p95_search_steps_upper = histogram_quantile_upper(
        diag and diag.histograms.search_steps_per_plan,
        0.95
      ),
      p99_search_steps_upper = histogram_quantile_upper(
        diag and diag.histograms.search_steps_per_plan,
        0.99
      ),
      p95_search_cpu_us_upper = histogram_quantile_upper(
        diag and diag.histograms.search_cpu_us_per_plan,
        0.95
      ),
      p99_search_cpu_us_upper = histogram_quantile_upper(
        diag and diag.histograms.search_cpu_us_per_plan,
        0.99
      ),
      max_search_steps = maxima.search_steps_per_plan or 0,
      max_search_depth = maxima.search_depth or 0,
      max_pending = maxima.pending_requests or 0,
      component_fraction = (counters.frontier_roots_total or 0) > 0
          and (counters.component_roots_total or 0) / counters.frontier_roots_total
        or 1,
      state_duplicate_fraction = (counters.states_observed or 0) > 0
          and (counters.state_duplicates or 0) / counters.states_observed
        or 0,
      forced_exchanges = counters.forced_exchanges or 0,
      forced_claims = counters.forced_claims or 0,
      dynamic_request_fraction = request_total > 0
          and (counters.requests_dynamic or 0) / request_total
        or 0,
    }
  end
end

if #results == 0 then
  error('no performance cases matched the selected tiers and filter', 0)
end

local function json_escape(value)
  local s = tostring(value)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function is_array(value)
  if type(value) ~= 'table' then
    return false
  end
  local max, count = 0, 0
  for k in pairs(value) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then
      return false
    end
    if k > max then
      max = k
    end
    count = count + 1
  end
  return max == count
end

local function sorted_keys(value)
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function json_encode(value, indent)
  indent = indent or 0
  local kind = type(value)
  if kind == 'nil' then
    return 'null'
  end
  if kind == 'boolean' or kind == 'number' then
    return tostring(value)
  end
  if kind == 'string' then
    return json_escape(value)
  end
  if kind ~= 'table' then
    return json_escape(tostring(value))
  end
  local pad, child_pad = string.rep(' ', indent), string.rep(' ', indent + 2)
  if is_array(value) then
    if #value == 0 then
      return '[]'
    end
    local rows = {}
    for i = 1, #value do
      rows[i] = child_pad .. json_encode(value[i], indent + 2)
    end
    return '[\n' .. table.concat(rows, ',\n') .. '\n' .. pad .. ']'
  end
  local keys = sorted_keys(value)
  if #keys == 0 then
    return '{}'
  end
  local rows = {}
  for i = 1, #keys do
    local key = keys[i]
    rows[i] = child_pad .. json_escape(key) .. ': ' .. json_encode(value[key], indent + 2)
  end
  return '{\n' .. table.concat(rows, ',\n') .. '\n' .. pad .. '}'
end

local document = {
  schema = 'fibers-performance-v1',
  generated_at = os.date and os.date('!%Y-%m-%dT%H:%M:%SZ') or nil,
  lua_version = _VERSION,
  machine = machine,
  choice_seed = choice_seed,
  scale = scale,
  repeats = repeats,
  tiers = tiers_text,
  diagnostics = diagnostics,
  clock = Clock.name,
  results = results,
}

local function render_text()
  local lines = {}
  lines[#lines + 1] = 'fibers tiered performance suite'
  lines[#lines + 1] = string.format(
    'lua=%s machine=%s seed=%d scale=%s repeats=%d tiers=%s diagnostics=%s clock=%s',
    tostring(_VERSION),
    machine,
    choice_seed,
    tostring(scale),
    repeats,
    tiers_text,
    tostring(diagnostics),
    Clock.name
  )
  lines[#lines + 1] = string.format(
    '%-9s %-13s %-35s %10s %11s %11s %9s %10s %8s %7s %7s',
    'tier',
    'group',
    'case',
    'ops',
    'median ms',
    'us/op',
    'p99<=',
    'max steps',
    'branches',
    'comp%',
    'dyn%'
  )
  lines[#lines + 1] = string.rep('-', 147)
  for _, r in ipairs(results) do
    lines[#lines + 1] = string.format(
      '%-9s %-13s %-35s %10d %11.3f %11.3f %9d %10d %8.1f %6.1f%% %6.1f%%',
      r.tier,
      r.group,
      r.name,
      r.operations,
      r.median_seconds * 1000,
      r.median_us_per_op,
      r.p99_search_steps_upper,
      r.max_search_steps,
      r.branches_per_plan,
      r.component_fraction * 100,
      r.dynamic_request_fraction * 100
    )
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Diagnostic timings are separate from the headline medians.'
  return table.concat(lines, '\n') .. '\n'
end

local function csv_quote(value)
  local s = tostring(value or '')
  if s:find('[,\n"]') then
    s = '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function render_csv()
  local lines = {
    'tier,group,name,iterations,operations,median_seconds,min_seconds,max_seconds,'
      .. 'median_us_per_op,median_retained_kb,diagnostic_seconds,plans,search_calls,'
      .. 'search_calls_per_plan,branches_per_plan,p50_search_steps_upper,'
      .. 'p95_search_steps_upper,p99_search_steps_upper,p95_search_cpu_us_upper,'
      .. 'p99_search_cpu_us_upper,max_search_steps,max_search_depth,max_pending,'
      .. 'claim_branches,recruit_branches,footprint_checks,footprint_matches,'
      .. 'component_fraction,state_duplicate_fraction,forced_exchanges,forced_claims,'
      .. 'requests_analysable,requests_dynamic,dynamic_request_fraction,'
      .. 'component_roots_excluded,plan_reuse_eligible',
  }
  for _, r in ipairs(results) do
    local c = r.diagnostics and r.diagnostics.counters or {}
    local row = {
      r.tier,
      r.group,
      r.name,
      r.iterations,
      r.operations,
      string.format('%.9f', r.median_seconds),
      string.format('%.9f', r.min_seconds),
      string.format('%.9f', r.max_seconds),
      string.format('%.6f', r.median_us_per_op),
      string.format('%.3f', r.median_retained_kb),
      r.diagnostic_seconds and string.format('%.9f', r.diagnostic_seconds) or '',
      c.plans or 0,
      c.search_calls or 0,
      string.format('%.3f', r.search_calls_per_plan),
      string.format('%.3f', r.branches_per_plan),
      r.p50_search_steps_upper,
      r.p95_search_steps_upper,
      r.p99_search_steps_upper,
      r.p95_search_cpu_us_upper,
      r.p99_search_cpu_us_upper,
      r.max_search_steps,
      r.max_search_depth,
      r.max_pending,
      c.claim_branches or 0,
      c.recruit_branches or 0,
      c.footprint_checks or 0,
      c.footprint_matches or 0,
      string.format('%.6f', r.component_fraction),
      string.format('%.6f', r.state_duplicate_fraction),
      r.forced_exchanges,
      r.forced_claims,
      c.requests_analysable or 0,
      c.requests_dynamic or 0,
      string.format('%.6f', r.dynamic_request_fraction),
      c.component_roots_excluded or 0,
      c.plan_reuse_eligible or 0,
    }
    for i = 1, #row do
      row[i] = csv_quote(row[i])
    end
    lines[#lines + 1] = table.concat(row, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

local rendered
if format == 'json' then
  rendered = json_encode(document) .. '\n'
elseif format == 'csv' then
  rendered = render_csv()
else
  rendered = render_text()
end

io.write(rendered)
if output_path ~= '' then
  local file, err = io.open(output_path, 'wb')
  if not file then
    error('cannot write performance output: ' .. tostring(err), 0)
  end
  file:write(rendered)
  file:close()
end

if not rawget(_G, '_FIBERS_PERF_EMBEDDED') and os and os.exit then
  os.exit(0, false)
end
return document
