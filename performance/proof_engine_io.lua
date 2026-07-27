-- Structural proof-engine profile for external-resource workloads.
--
-- This is deliberately diagnostic rather than a headline throughput suite. It
-- runs the ordinary production lazy machine with instrumentation enabled and
-- reports the amount and shape of proof work required by each validated case.
--
-- Controls:
--   FIBERS_PROOF_SCALE=2
--   FIBERS_PROOF_CASE=datagram
--   FIBERS_PROOF_FORMAT=csv
--   FIBERS_PROOF_SLOW=1

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
  join_path(root, 'src/?.lua'),
  join_path(root, 'src/?/init.lua'),
  join_path(root, 'src/?/?.lua'),
  join_path(root, '?.lua'),
  join_path(root, '?/init.lua'),
  join_path(root, '?/?.lua'),
  package.path,
}, ';')

local fibers = require('fibers')
local File = require('fibers.file')
local SimulatedHost = require('tests.support.simulated_host')
local Runtime = require('fibers.runtime')
local Socket = require('fibers.socket')
local Stream = require('fibers.stream')
local Clock = require('performance.clock')

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or '')
  if not value or value <= 0 then
    return default
  end
  return value
end

local scale = env_number('FIBERS_PROOF_SCALE', 1)
local filter = os.getenv('FIBERS_PROOF_CASE') or ''
local format = os.getenv('FIBERS_PROOF_FORMAT') or 'text'
local show_slow = os.getenv('FIBERS_PROOF_SLOW') == '1'
local trace = os.getenv('FIBERS_PROOF_TRACE') == '1'

local cases = {}
local function add(name, units, host, body)
  cases[#cases + 1] = {
    name = name,
    units = units,
    host = host,
    body = body,
  }
end

add('memory-stream', 'bytes', function()
  return SimulatedHost.new({ pipes = true })
end, function(scope)
  local chunks = math.max(1, math.floor(16 * scale))
  local chunk = string.rep('x', 4096)
  local expected = chunks * #chunk
  local writer, reader = Stream.memory_pair({
    name = 'proof-memory-stream',
    capacity = 32768,
  })
  local producer = scope:spawn(function()
    for _ = 1, chunks do
      writer:write(chunk)
    end
    writer:shutdown_write('proof profile complete')
  end, 'proof-memory-writer')
  local total = 0
  while total < expected do
    total = total + #assert(reader:read_some(math.min(16384, expected - total)))
  end
  producer:await()
  writer:close('proof profile complete')
  reader:close('proof profile complete')
  assert(total == expected)
  return expected
end)

add('socket-lifecycle', 'connections', function()
  return SimulatedHost.new({ sockets = true, pipes = true })
end, function(scope)
  local count = math.max(1, math.floor(2 * scale))
  local accepted = 0
  local listener = assert(Socket.listen_ipv4('127.0.0.1', 0, {
    accept_capacity = count,
  }))
  local address = listener:local_address()
  local server = scope:spawn(function()
    for _ = 1, count do
      local connection = assert(listener:accept())
      accepted = accepted + 1
      connection:close('proof profile accepted')
    end
  end, 'proof-socket-server')
  for _ = 1, count do
    local dial = Socket.dial(address)
    local connection = assert(dial:result())
    connection:close('proof profile dialled')
  end
  server:await()
  listener:close('proof profile complete')
  assert(accepted == count)
  return count
end)

add('datagram-roundtrip', 'datagrams', function()
  return SimulatedHost.new({ datagrams = true })
end, function()
  local count = math.max(1, math.floor(16 * scale))
  local sender = assert(Socket.udp_ipv4('127.0.0.1', 0, {
    send_capacity = count,
  }))
  local receiver = assert(Socket.udp_ipv4('127.0.0.1', 0, {
    receive_capacity = count,
  }))
  for i = 1, count do
    sender:send_to(tostring(i), receiver:local_address())
  end
  sender:flush()
  for i = 1, count do
    assert(assert(receiver:receive_from()).data == tostring(i))
  end
  sender:close('proof profile complete')
  receiver:close('proof profile complete')
  return count
end)

add('reactor-registration', 'registrations', function()
  return SimulatedHost.new({ pipes = true })
end, function()
  local count = math.max(1, math.floor(4 * scale))
  local endpoints = {}
  for i = 1, count do
    local reader, writer = assert(File.pipe({ name = 'proof-pipe-' .. tostring(i) }))
    endpoints[#endpoints + 1] = reader
    endpoints[#endpoints + 1] = writer
  end
  local runtime = Runtime.current()
  local registrations = runtime.host_reactor and runtime.host_reactor:registration_count() or 0
  assert(registrations == count * 2)
  for i = 1, #endpoints do
    endpoints[i]:close('proof profile complete')
  end
  return registrations
end)

local columns = {
  'case',
  'units',
  'elapsed_ms',
  'plans',
  'commits',
  'search_calls',
  'branches',
  'claim_branches',
  'claim_closure_branches',
  'claim_closure_successes',
  'claim_closure_failures',
  'forced_claims',
  'rollbacks',
  'trail_entries',
  'trail_coalesced',
  'option_nodes',
  'dependency_locations',
  'dependency_resources',
  'dependency_exchanges',
  'max_component',
  'search_per_commit',
  'branches_per_commit',
  'trail_per_commit',
}

local function ratio(value, divisor)
  if not divisor or divisor == 0 then
    return 0
  end
  return value / divisor
end

local rows = {}
for _, case in ipairs(cases) do
  if filter == '' or case.name:find(filter, 1, true) then
    collectgarbage('collect')
    local started = Clock.now()
    local units
    local result = fibers.try_run(function(scope)
      units = case.body(scope)
    end, {
      host = case.host(),
      verify_dependencies = true,
      instrumentation = {
        slow_plan_limit = show_slow and 8 or 0,
        trace = trace,
        trace_limit = trace and 2048 or 0,
      },
    })
    assert(result.ok, tostring(result.primary))
    local elapsed = Clock.now() - started
    local snapshot = result.runtime:instrumentation_report()
    local counters = snapshot.counters or {}
    local commits = counters.commits or 0
    local row = {
      case = case.name,
      units = units,
      elapsed_ms = elapsed * 1000,
      plans = counters.plans or 0,
      commits = commits,
      search_calls = counters.search_calls or 0,
      branches = counters.branches or 0,
      claim_branches = counters.claim_branches or 0,
      claim_closure_branches = counters.claim_closure_branches or 0,
      claim_closure_successes = counters.claim_closure_successes or 0,
      claim_closure_failures = counters.claim_closure_failures or 0,
      forced_claims = counters.forced_claims or 0,
      rollbacks = counters.rollbacks or 0,
      trail_entries = counters.trail_entries or 0,
      trail_coalesced = (counters.trail_set_coalesced or 0) + (counters.trail_push_coalesced or 0),
      option_nodes = counters.option_nodes or 0,
      dependency_locations = counters.dependency_locations or 0,
      dependency_resources = counters.dependency_resources or 0,
      dependency_exchanges = counters.dependency_exchanges or 0,
      max_component = (snapshot.maxima or {}).component_size or 0,
      plan_reuse_hits = counters.plan_reuse_hits or 0,
      plan_reuse_invalidations = counters.plan_reuse_invalidations or 0,
      search_session_resumes = counters.search_session_resumes or 0,
      invalid_request = counters.search_session_invalidation_request or 0,
      invalid_bucket = counters.search_session_invalidation_bucket or 0,
      invalid_location = counters.search_session_invalidation_location or 0,
      invalid_resource = counters.search_session_invalidation_resource or 0,
      invalid_external = counters.search_session_invalidation_external_generation or 0,
      invalid_epoch = counters.search_session_invalidation_runtime_epoch or 0,
      invalid_timer = counters.search_session_invalidation_timer or 0,
      search_per_commit = ratio(counters.search_calls or 0, commits),
      branches_per_commit = ratio(counters.branches or 0, commits),
      trail_per_commit = ratio(counters.trail_entries or 0, commits),
      slow_plans = snapshot.slow_plans,
    }
    rows[#rows + 1] = row
  end
end

if format == 'csv' then
  print(table.concat(columns, ','))
  for _, row in ipairs(rows) do
    local values = {}
    for i = 1, #columns do
      local value = row[columns[i]]
      if type(value) == 'number' then
        values[i] = string.format('%.6f', value)
      else
        values[i] = tostring(value)
      end
    end
    print(table.concat(values, ','))
  end
else
  print('Fibers proof-engine I/O profile (' .. Clock.name .. ')')
  for _, row in ipairs(rows) do
    print(
      string.format(
        '%-22s %7.1f ms  plans=%-4d commits=%-4d search/commit=%6.1f branches/commit=%6.1f trail/commit=%7.1f',
        row.case,
        row.elapsed_ms,
        row.plans,
        row.commits,
        row.search_per_commit,
        row.branches_per_commit,
        row.trail_per_commit
      )
    )
    print(
      string.format(
        '  claims=%d closure=%d/%d/%d forced=%d rollbacks=%d coalesced=%d nodes=%d deps(loc=%d,res=%d,exchange=%d) max_component=%d',
        row.claim_branches,
        row.claim_closure_branches,
        row.claim_closure_successes,
        row.claim_closure_failures,
        row.forced_claims,
        row.rollbacks,
        row.trail_coalesced,
        row.option_nodes,
        row.dependency_locations,
        row.dependency_resources,
        row.dependency_exchanges,
        row.max_component
      )
    )
    print(
      string.format(
        '  reuse(hit=%d invalid=%d resume=%d) invalid(req=%d,bucket=%d,loc=%d,res=%d,ext=%d,epoch=%d,timer=%d)',
        row.plan_reuse_hits,
        row.plan_reuse_invalidations,
        row.search_session_resumes,
        row.invalid_request,
        row.invalid_bucket,
        row.invalid_location,
        row.invalid_resource,
        row.invalid_external,
        row.invalid_epoch,
        row.invalid_timer
      )
    )
    if show_slow then
      for i, plan in ipairs(row.slow_plans or {}) do
        print(
          string.format(
            '    slow[%d] steps=%d branches=%d claims=%d closure=%d/%d/%d forced=%d roots=%d nodes=%d dynamic=%d outcome=%s',
            i,
            plan.search_steps or 0,
            plan.branches or 0,
            plan.claim_branches or 0,
            plan.claim_closure_branches or 0,
            plan.claim_closure_successes or 0,
            plan.claim_closure_failures or 0,
            plan.forced_claims or 0,
            plan.component_size or 0,
            plan.option_nodes or 0,
            plan.option_dynamic_roots or 0,
            tostring(plan.outcome)
          )
        )
        if trace and i == 1 then
          for _, request in ipairs(plan.request_summaries or {}) do
            local kinds = {}
            for kind, count in pairs(request.kinds or {}) do
              kinds[#kinds + 1] = tostring(kind) .. ':' .. tostring(count)
            end
            table.sort(kinds)
            print(
              string.format(
                '      request id=%s name=%s dynamic=%s external=%s nodes=%s kinds=%s',
                tostring(request.id),
                tostring(request.name),
                tostring(request.dynamic),
                tostring(request.external),
                tostring(request.nodes),
                table.concat(kinds, '|')
              )
            )
          end
          for _, event in ipairs(plan.events or {}) do
            if event.kind == 'claim_group' or event.kind == 'claim_branch' then
              print(
                string.format(
                  '      %s key=%s size=%s kind=%s all_machine=%s group_accepts=%s'
                    .. ' names=%s supply_sets=%s accepts=%s modes=%s',
                  tostring(event.kind),
                  tostring(event.group_key or event.key),
                  tostring(event.size),
                  tostring(event.claim_kind or ''),
                  tostring(event.all_machine or ''),
                  event.group_accepts_supply == nil and '' or tostring(event.group_accepts_supply),
                  tostring(event.names or ''),
                  tostring(event.supply_sets or ''),
                  tostring(event.accepts_supply or ''),
                  tostring(event.modes or '')
                )
              )
            end
          end
        end
      end
    end
  end
end
