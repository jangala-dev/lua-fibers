-- Sweep the known high-branching nursery/rendezvous shape across fanout sizes
-- and choice seeds.  Output is CSV so it can be plotted or compared easily.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Clock = require('performance.clock')

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or '')
  return value or default
end

local min_size = math.max(2, math.floor(env_number('FIBERS_SWEEP_MIN_SIZE', 4)))
local max_size = math.max(min_size, math.floor(env_number('FIBERS_SWEEP_MAX_SIZE', 7)))
local min_seed = math.floor(env_number('FIBERS_SWEEP_MIN_SEED', 1))
local max_seed = math.max(min_seed, math.floor(env_number('FIBERS_SWEEP_MAX_SEED', 8)))
local search_limit = math.max(1, math.floor(env_number('FIBERS_SWEEP_SEARCH_LIMIT', 1000000)))
local output = os.getenv('FIBERS_SWEEP_OUTPUT') or ''

local lines = {
  'fanout,seed,status,elapsed_seconds,plans,search_calls,branches,rollbacks,trail_entries,intent_pairs_scanned,compatible_pairs,claim_branches,recruit_branches,exclude_branches,footprint_checks,footprint_matches,footprint_dynamic_matches,footprint_exchange_matches,footprint_location_matches,max_search_steps,max_search_depth,max_intents,max_roots,max_claim_group,max_trail'
}

for fanout = min_size, max_size do
  for seed = min_seed, max_seed do
    collectgarbage('collect')
    local total = 0
    local started = Clock.now()
    local result = fibers.try_run(function()
      local ch = fibers.Rendezvous.new('seed-sweep-' .. tostring(fanout) .. '-' .. tostring(seed))
      for i = 1, fanout do
        fibers.spawn(function() fibers.perform(ch:put_op(i)) end, 'seed-child-' .. tostring(i))
      end
      for _ = 1, fanout do total = total + fibers.perform(ch:get_op()) end
    end, {
      name = 'seed-sweep',
      choice_seed = seed,
      search_limit = search_limit,
      instrumentation = { slow_plan_limit = 1, clock = Clock.now },
      policy = fibers.policy.nursery({ name = 'seed-sweep-policy' }),
    })
    local elapsed = Clock.now() - started
    local snapshot = result.runtime and result.runtime:instrumentation_snapshot() or { counters = {}, maxima = {} }
    local c, m = snapshot.counters or {}, snapshot.maxima or {}
    local status = result.ok and 'ok' or tostring(result.reason or 'failed')
    if result.ok and total ~= fanout * (fanout + 1) / 2 then status = 'wrong-result' end
    lines[#lines + 1] = table.concat({
      fanout, seed, status, string.format('%.9f', elapsed), c.plans or 0,
      c.search_calls or 0, c.branches or 0, c.rollbacks or 0, c.trail_entries or 0,
      c.intent_pairs_scanned or 0, c.compatible_pairs or 0, c.claim_branches or 0,
      c.recruit_branches or 0, c.exclude_branches or 0, c.footprint_checks or 0,
      c.footprint_matches or 0, c.footprint_dynamic_matches or 0,
      c.footprint_exchange_matches or 0, c.footprint_location_matches or 0,
      m.search_steps_per_plan or 0, m.search_depth or 0, m.intents or 0,
      m.roots or 0, m.claim_group_size or 0, m.trail_entries_live or 0,
    }, ',')
    io.stderr:write(string.format('fanout=%d seed=%d status=%s elapsed=%.3fs max_steps=%d\n',
      fanout, seed, status, elapsed, m.search_steps_per_plan or 0))
  end
end

local text = table.concat(lines, '\n') .. '\n'
io.write(text)
if output ~= '' then
  local file = assert(io.open(output, 'wb'))
  file:write(text)
  file:close()
end

if os and os.exit then os.exit(0, false) end
