-- Structural suite for the current performance architecture.
--
-- This suite includes instrumentation in its elapsed figures deliberately: its
-- primary outputs are solver work and component shape, not headline throughput.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')
local Op = require('fibers.op')
local fibers = require('fibers')
local Policy = require('fibers.policy')
local Clock = require('performance.clock')

local function env(name, default)
  local value = os.getenv(name)
  if value == nil or value == '' then
    return default
  end
  return value
end
local function env_number(name, default)
  return tonumber(env(name, '')) or default
end

local repeats = math.max(1, math.floor(env_number('FIBERS_ARCH_REPEATS', 2)))
local format = env('FIBERS_ARCH_FORMAT', 'text')
local output = env('FIBERS_ARCH_OUTPUT', '')
local case_filter = env('FIBERS_ARCH_CASE', '')
local machines_text = env('FIBERS_ARCH_MACHINES', 'ledger,reference')
local include_fanout8 = env_number('FIBERS_ARCH_FANOUT8', 0) ~= 0

local machines = {}
for value in machines_text:gmatch('[^,%s]+') do
  machines[#machines + 1] = value
end

local profiles = {
  {
    name = 'architecture',
    options = {
      component_search = true,
      normalise_search = true,
    },
  },
}

local function copy_options(base, additions)
  local out = {}
  for k, v in pairs(base or {}) do
    out[k] = v
  end
  for k, v in pairs(additions or {}) do
    out[k] = v
  end
  return out
end

local function drain(rt)
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  return status
end

local function runtime(profile, machine, extra)
  return Runtime.new(copy_options(
    profile.options,
    copy_options(extra, {
      machine = machine,
      instrumentation = { clock = Clock.now, slow_plan_limit = 3 },
    })
  ))
end

local scenarios = {}
local function add(name, run)
  scenarios[#scenarios + 1] = { name = name, run = run }
end

add('isolated blocked components', function(profile, machine)
  local rt = runtime(profile, machine)
  for i = 1, 24 do
    local channel = Rendezvous.new('arch-isolated-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(channel:get_op())
    end)
  end
  local status = drain(rt)
  assert(status.tag == 'quiescent')
  return rt, 'quiescent:24'
end)

add('hinted continuation isolation', function(profile, machine)
  local rt =
    runtime(profile, machine, { dependency_index_threshold = 1, dependency_index_release_threshold = 0 })
  local focus = Rendezvous.new('arch-hinted-focus')
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      return focus:get_op()
    end, Op.dependencies(focus:get_op())))
  end)
  for i = 1, 12 do
    local channel = Rendezvous.new('arch-hinted-unrelated-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(channel:get_op())
    end)
  end
  local status = drain(rt)
  assert(status.tag == 'quiescent')
  return rt, 'quiescent:13'
end)

add('opaque continuation slow path', function(profile, machine)
  local rt =
    runtime(profile, machine, { dependency_index_threshold = 1, dependency_index_release_threshold = 0 })
  local focus = Rendezvous.new('arch-opaque-focus')
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      return focus:get_op()
    end))
  end)
  for i = 1, 12 do
    local channel = Rendezvous.new('arch-opaque-unrelated-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(channel:get_op())
    end)
  end
  local status = drain(rt)
  assert(status.tag == 'quiescent')
  return rt, 'quiescent:13'
end)

add('binary rendezvous sequence', function(profile, machine)
  local rt = runtime(profile, machine)
  local channel = Rendezvous.new('arch-binary')
  local total, n = 0, 80
  rt:spawn_raw(function()
    for _ = 1, n do
      total = total + rt:perform(channel:get_op())
    end
  end)
  rt:spawn_raw(function()
    for i = 1, n do
      rt:perform(channel:put_op(i))
    end
  end)
  local status = drain(rt)
  assert(status.tag == 'idle' or status.tag == 'quiescent')
  local expected = n * (n + 1) / 2
  assert(total == expected)
  return rt, 'sum:' .. tostring(total)
end)

add('forced scalar query sequence', function(profile, machine)
  local rt = runtime(profile, machine)
  local scalar = Scalar.machine(9, 'arch-forced-scalar')
  local total, n = 0, 80
  rt:spawn_raw(function()
    for _ = 1, n do
      if rt:perform(scalar:expect_op(9)) then
        total = total + 1
      end
    end
  end)
  local status = drain(rt)
  assert(status.tag == 'idle' or status.tag == 'quiescent')
  assert(total == n)
  return rt, 'count:' .. tostring(total)
end)

add('contended producers', function(profile, machine)
  local rt = runtime(profile, machine)
  local channel = Rendezvous.new('arch-contention')
  local producers, messages, total = 8, 4, 0
  for producer = 1, producers do
    rt:spawn_raw(function()
      for message = 1, messages do
        rt:perform(channel:put_op(producer * 100 + message))
      end
    end)
  end
  rt:spawn_raw(function()
    for _ = 1, producers * messages do
      total = total + rt:perform(channel:get_op())
    end
  end)
  local status = drain(rt)
  assert(status.tag == 'idle' or status.tag == 'quiescent')
  return rt, 'sum:' .. tostring(total)
end)

add('triple swap with decoy', function(profile, machine)
  local rt = runtime(profile, machine)
  local ab, bc, ca = Rendezvous.new('arch-ab'), Rendezvous.new('arch-bc'), Rendezvous.new('arch-ca')
  local a, b, c
  rt:spawn_raw(function()
    a = rt:perform(Op.all({ ab:put_op('A'), ca:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end)
  rt:spawn_raw(function()
    b = rt:perform(Op.all({ bc:put_op('B'), ab:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end)
  rt:spawn_raw(function()
    c = rt:perform(Op.all({ ca:put_op('C'), bc:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end)
  rt:spawn_raw(function()
    rt:perform(ab:get_op())
  end)
  drain(rt)
  assert(a == 'C' and b == 'A' and c == 'B')
  return rt, table.concat({ a, b, c }, ':')
end)

local function nursery_case(fanout)
  return function(profile, machine)
    local total = 0
    local opts = copy_options(profile.options, {
      name = 'arch-nursery-' .. tostring(fanout),
      machine = machine,
      choice_seed = 1,
      instrumentation = { clock = Clock.now, slow_plan_limit = 3 },
      policy = Policy.nursery({ name = 'arch-nursery-policy' }),
    })
    local result = fibers.try_run(function()
      local channel = Rendezvous.new('arch-nursery-channel-' .. tostring(fanout))
      for i = 1, fanout do
        fibers.spawn(function()
          fibers.perform(channel:put_op(i))
        end, 'arch-child-' .. tostring(i))
      end
      for _ = 1, fanout do
        total = total + fibers.perform(channel:get_op())
      end
    end, opts)
    assert(result.ok, tostring(result.report or result.reason))
    assert(total == fanout * (fanout + 1) / 2)
    return result.runtime, 'sum:' .. tostring(total)
  end
end
add('nursery rendezvous fanout seven', nursery_case(7))
if include_fanout8 then
  add('nursery rendezvous fanout eight', nursery_case(8))
end

local function median(xs)
  table.sort(xs)
  local n = #xs
  return n % 2 == 1 and xs[(n + 1) / 2] or (xs[n / 2] + xs[n / 2 + 1]) / 2
end

local rows, digests = {}, {}
for _, scenario in ipairs(scenarios) do
  if case_filter == '' or scenario.name:find(case_filter, 1, true) then
    for _, profile in ipairs(profiles) do
      for _, machine in ipairs(machines) do
        local elapsed_samples, last_snapshot, digest = {}, nil, nil
        for _ = 1, repeats do
          collectgarbage('collect')
          local started = Clock.now()
          local rt, value = scenario.run(profile, machine)
          elapsed_samples[#elapsed_samples + 1] = Clock.now() - started
          last_snapshot = rt:instrumentation_snapshot()
          if digest ~= nil then
            assert(digest == value, 'non-replayable scenario digest')
          end
          digest = value
        end
        local key = scenario.name
        if digests[key] ~= nil then
          assert(digests[key] == digest, 'semantic digest differs for ' .. key)
        else
          digests[key] = digest
        end
        local c, m = last_snapshot.counters or {}, last_snapshot.maxima or {}
        rows[#rows + 1] = {
          case = scenario.name,
          profile = profile.name,
          machine = machine,
          elapsed = median(elapsed_samples),
          digest = digest,
          plans = c.plans or 0,
          search_calls = c.search_calls or 0,
          branches = c.branches or 0,
          max_steps = m.search_steps_per_plan or 0,
          component_fraction = (c.frontier_roots_total or 0) > 0
              and (c.component_roots_total or 0) / c.frontier_roots_total
            or 1,
          excluded = c.component_roots_excluded or 0,
          forced_exchanges = c.forced_exchanges or 0,
          forced_claims = c.forced_claims or 0,
          dynamic = c.requests_dynamic or 0,
          analysable = c.requests_analysable or 0,
          pair_scans = c.intent_pairs_scanned or 0,
          footprint_checks = c.footprint_checks or 0,
        }
      end
    end
  end
end
assert(#rows > 0, 'no architecture cases matched')

local function quote(x)
  local s = tostring(x or '')
  if s:find('[,\n"]') then
    s = '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function render_csv()
  local lines = {
    'case,profile,machine,median_seconds,digest,plans,search_calls,branches,'
      .. 'max_search_steps,component_fraction,component_roots_excluded,forced_exchanges,'
      .. 'forced_claims,requests_analysable,requests_dynamic,'
      .. 'intent_pairs_scanned,footprint_checks',
  }
  for _, r in ipairs(rows) do
    local values = {
      r.case,
      r.profile,
      r.machine,
      string.format('%.9f', r.elapsed),
      r.digest,
      r.plans,
      r.search_calls,
      r.branches,
      r.max_steps,
      string.format('%.6f', r.component_fraction),
      r.excluded,
      r.forced_exchanges,
      r.forced_claims,
      r.analysable,
      r.dynamic,
      r.pair_scans,
      r.footprint_checks,
    }
    for i = 1, #values do
      values[i] = quote(values[i])
    end
    lines[#lines + 1] = table.concat(values, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

local function render_text()
  local lines = {
    'fibers performance architecture suite',
    string.format(
      'lua=%s repeats=%d machines=%s clock=%s',
      tostring(_VERSION),
      repeats,
      machines_text,
      Clock.name
    ),
    string.format(
      '%-34s %-12s %-9s %9s %9s %9s %8s %7s %7s',
      'case',
      'profile',
      'machine',
      'median ms',
      'max step',
      'branches',
      'comp%',
      'forced',
      'dynamic'
    ),
    string.rep('-', 115),
  }
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format(
      '%-34s %-12s %-9s %9.3f %9d %9d %7.1f%% %7d %7d',
      r.case,
      r.profile,
      r.machine,
      r.elapsed * 1000,
      r.max_steps,
      r.branches,
      r.component_fraction * 100,
      r.forced_exchanges + r.forced_claims,
      r.dynamic
    )
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'All evaluator variants produced the same validating digest per case.'
  return table.concat(lines, '\n') .. '\n'
end

local rendered = format == 'csv' and render_csv() or render_text()
io.write(rendered)
if output ~= '' then
  local f = assert(io.open(output, 'wb'))
  f:write(rendered)
  f:close()
end
