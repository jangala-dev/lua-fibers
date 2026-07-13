-- Structural benchmark suite for refutation caching, state memoisation,
-- certified symmetry and cross-cycle plan reuse.

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

local Runtime = require('fibers.kernel.runtime')
local Rendezvous = require('fibers.atoms.rendezvous')
local Scalar = require('fibers.atoms.scalar')
local Op = require('fibers.atoms.op')
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
local repeats = math.max(1, math.floor(env_number('FIBERS_ADV_REPEATS', 3)))
local format = env('FIBERS_ADV_FORMAT', 'text')
local output = env('FIBERS_ADV_OUTPUT', '')
local machine = env('FIBERS_ADV_MACHINE', 'trail')
local case_filter = env('FIBERS_ADV_CASE', '')

local profiles = {
  {
    name = 'baseline',
    opts = {
      refutation_cache = false,
      state_memoization = false,
      certified_symmetry = false,
      plan_reuse = false,
    },
  },
  {
    name = 'refutation',
    opts = {
      refutation_cache = true,
      state_memoization = false,
      certified_symmetry = false,
      plan_reuse = false,
    },
  },
  {
    name = 'memo',
    opts = {
      refutation_cache = true,
      state_memoization = true,
      certified_symmetry = false,
      plan_reuse = false,
    },
  },
  {
    name = 'full',
    opts = {
      refutation_cache = true,
      state_memoization = true,
      certified_symmetry = true,
      plan_reuse = true,
    },
  },
}

local function copy(base, extra)
  local out = {}
  for k, v in pairs(base or {}) do
    out[k] = v
  end
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

local function runtime(profile, extra)
  return Runtime.new(copy(
    profile.opts,
    copy(extra, {
      machine = machine,
      instrumentation = { clock = Clock.now, state_hash = true, slow_plan_limit = 3 },
    })
  ))
end

local function drain(rt)
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  return status
end

local scenarios = {}
local function add(name, run)
  scenarios[#scenarios + 1] = { name = name, run = run }
end

add('duplicate blocked alternatives', function(profile)
  local rt = runtime(profile)
  local channel = Rendezvous.new('adv-duplicate')
  local blocked = channel:get_op()
  local alternatives = {}
  for i = 1, 128 do
    alternatives[i] = blocked
  end
  rt:spawn_raw(function()
    rt:perform(Op.choice(alternatives))
  end)
  assert(drain(rt).tag == 'quiescent')
  return rt, 'retry:128'
end)

add('repeated supplier no-good', function(profile)
  local rt = runtime(profile, { component_search = false })
  local target = Rendezvous.new('adv-no-good-target')
  local blocked = target:get_op()
  local alternatives = {}
  for i = 1, 96 do
    alternatives[i] = blocked
  end
  rt:spawn_raw(function()
    rt:perform(Op.choice(alternatives))
  end)
  for i = 1, 64 do
    local noise = Rendezvous.new('adv-no-good-noise-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(noise:get_op())
    end)
  end
  assert(drain(rt).tag == 'quiescent')
  return rt, 'retry:96+64'
end)

add('certified symmetric suppliers', function(profile)
  local rt = runtime(profile, { dependency_index_threshold = 1 })
  local channel = Rendezvous.new('adv-symmetry')
  local scalar = Scalar.new(0, 'adv-symmetry-state')
  for _ = 1, 10 do
    rt:spawn_raw(function()
      rt:perform(channel:put_op(1):certify_symmetry('equivalent-producer'))
    end)
  end
  rt:spawn_raw(function()
    rt:perform(Op.tensor({ channel:get_op(), scalar:write_op(1), scalar:write_op(2) }))
  end)
  assert(drain(rt).tag == 'quiescent')
  return rt, 'retry:10'
end)

add('repeated blocked driver cycles', function(profile)
  local rt = runtime(profile)
  for i = 1, 32 do
    local channel = Rendezvous.new('adv-reuse-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(channel:get_op())
    end)
  end
  assert(drain(rt).tag == 'quiescent')
  for _ = 1, 8 do
    assert(drain(rt).tag == 'quiescent')
  end
  return rt, 'cycles:9'
end)

add('ordinary binary rendezvous', function(profile)
  local rt = runtime(profile)
  local request = Rendezvous.new('adv-ping')
  local reply = Rendezvous.new('adv-pong')
  local total, count = 0, 300
  rt:spawn_raw(function()
    for i = 1, count do
      rt:perform(request:put_op(i))
      total = total + rt:perform(reply:get_op())
    end
  end)
  rt:spawn_raw(function()
    for _ = 1, count do
      local value = rt:perform(request:get_op())
      rt:perform(reply:put_op(value))
    end
  end)
  assert(drain(rt).tag == 'idle')
  assert(total == count * (count + 1) / 2)
  return rt, 'sum:' .. tostring(total)
end)

add('triple swap with decoy', function(profile)
  local rt = runtime(profile)
  local ab, bc, ca = Rendezvous.new('adv-ab'), Rendezvous.new('adv-bc'), Rendezvous.new('adv-ca')
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

local function median(values)
  table.sort(values)
  local n = #values
  return n % 2 == 1 and values[(n + 1) / 2] or (values[n / 2] + values[n / 2 + 1]) / 2
end

local rows, expected = {}, {}
for _, scenario in ipairs(scenarios) do
  if case_filter == '' or scenario.name:find(case_filter, 1, true) then
    for _, profile in ipairs(profiles) do
      local elapsed, final_rt, digest = {}, nil, nil
      for i = 1, repeats do
        local started = Clock.now()
        local rt, value = scenario.run(profile)
        elapsed[i] = Clock.now() - started
        final_rt, digest = rt, value
      end
      expected[scenario.name] = expected[scenario.name] or digest
      assert(
        expected[scenario.name] == digest,
        'profile changed validating digest for ' .. scenario.name
      )
      local snap = final_rt:instrumentation_snapshot()
      local c, m = snap.counters, snap.maxima
      rows[#rows + 1] = {
        case = scenario.name,
        profile = profile.name,
        seconds = median(elapsed),
        digest = digest,
        plans = c.plans or 0,
        calls = c.search_calls or 0,
        branches = c.branches or 0,
        max_steps = m.search_steps_per_plan or 0,
        ref_hits = c.refutation_cache_hits or 0,
        supplier_hits = c.supplier_refutation_hits or 0,
        memo_hits = c.state_memo_hits or 0,
        footprint_checks = c.footprint_checks or 0,
        symmetry = (c.symmetry_supplier_pruned or 0) + (c.symmetry_exchange_pruned or 0),
        reuse = c.plan_reuse_hits or 0,
        invalidations = c.plan_reuse_invalidations or 0,
        cache_entries = m.plan_cache_entries or 0,
      }
    end
  end
end

local function quote(value)
  local text = tostring(value or '')
  if text:find('[,\n"]') then
    text = '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function csv()
  local lines = {
    'case,profile,machine,median_seconds,digest,plans,search_calls,branches,'
      .. 'max_search_steps,footprint_checks,refutation_hits,supplier_refutation_hits,'
      .. 'state_memo_hits,symmetry_pruned,plan_reuse_hits,plan_reuse_invalidations,'
      .. 'max_plan_cache_entries',
  }
  for _, row in ipairs(rows) do
    local values = {
      row.case,
      row.profile,
      machine,
      string.format('%.9f', row.seconds),
      row.digest,
      row.plans,
      row.calls,
      row.branches,
      row.max_steps,
      row.footprint_checks,
      row.ref_hits,
      row.supplier_hits,
      row.memo_hits,
      row.symmetry,
      row.reuse,
      row.invalidations,
      row.cache_entries,
    }
    for i = 1, #values do
      values[i] = quote(values[i])
    end
    lines[#lines + 1] = table.concat(values, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

local function text()
  local lines = {
    'fibers advanced performance suite',
    string.format(
      'lua=%s machine=%s repeats=%d clock=%s',
      tostring(_VERSION),
      machine,
      repeats,
      Clock.name
    ),
    string.format(
      '%-34s %-11s %9s %9s %9s %9s %8s %8s %8s %8s',
      'case',
      'profile',
      'median ms',
      'calls',
      'branches',
      'fp checks',
      'ref hit',
      'memo',
      'sym',
      'reuse'
    ),
    string.rep('-', 122),
  }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format(
      '%-34s %-11s %9.3f %9d %9d %9d %8d %8d %8d %8d',
      row.case,
      row.profile,
      row.seconds * 1000,
      row.calls,
      row.branches,
      row.footprint_checks,
      row.ref_hits,
      row.memo_hits,
      row.symmetry,
      row.reuse
    )
  end
  return table.concat(lines, '\n') .. '\n'
end

local rendered = format == 'csv' and csv() or text()
io.write(rendered)
if output ~= '' then
  local handle = assert(io.open(output, 'wb'))
  handle:write(rendered)
  handle:close()
end
