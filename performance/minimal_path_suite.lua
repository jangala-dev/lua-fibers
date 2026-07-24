-- Focused benchmark for the minimal transaction path.
--
-- Timings and GC-disabled allocation are measured separately.  The diagnostic
-- pass records the amount of abstract-machine and pooling work without
-- contaminating headline timings.

local argv0 = (arg and arg[0]) or ''
local here = argv0:match('^(.*[/\\])[^/\\]*$') or ''
local root = here:gsub('performance[/\\]$', '')
local function join(prefix, suffix)
  return prefix == '' and suffix or prefix .. suffix
end
package.path = table.concat({
  join(root, 'src/?.lua'),
  join(root, 'src/?/init.lua'),
  join(root, 'src/?/?.lua'),
  join(root, 'reference/?.lua'),
  join(root, 'reference/?/init.lua'),
  join(root, 'reference/?/?.lua'),
  join(root, '?.lua'),
  join(root, '?/init.lua'),
  join(root, '?/?.lua'),
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')
local Clock = require('performance.clock')

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or '')
  return value == nil and default or value
end

local iterations = math.max(1, math.floor(env_number('FIBERS_MINIMAL_ITERATIONS', 4000)))
local repeats = math.max(1, math.floor(env_number('FIBERS_MINIMAL_REPEATS', 5)))
local format = os.getenv('FIBERS_MINIMAL_FORMAT') or 'text'
local output = os.getenv('FIBERS_MINIMAL_OUTPUT') or ''
local machine = os.getenv('FIBERS_MINIMAL_MACHINE') or 'ledger'
local function runtime(instrumented)
  local opts = {
    machine = machine,
    instrumentation = instrumented and { clock = Clock.now } or nil,
    search_session_pool = env_number('FIBERS_MINIMAL_SESSION_POOL', 1) ~= 0,
  }
  return Runtime.new(opts)
end

local function drain(rt)
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  if status.tag ~= 'idle' and status.tag ~= 'quiescent' and status.tag ~= 'pending' then
    error('runtime did not drain: ' .. tostring(status.tag), 2)
  end
end

local cases = {
  {
    name = 'always',
    operations = function(n)
      return n
    end,
    run = function(n, instrumented)
      local rt = runtime(instrumented)
      local operation = Op.always(1)
      local total = 0
      rt:spawn_raw(function()
        for _ = 1, n do
          total = total + rt:perform(operation)
        end
      end, 'minimal-always')
      drain(rt)
      assert(total == n)
      return rt
    end,
  },
  {
    name = 'scalar_read',
    operations = function(n)
      return n
    end,
    run = function(n, instrumented)
      local rt = runtime(instrumented)
      local scalar = Scalar.new(7, 'minimal-scalar')
      local operation = scalar:read_op()
      local total = 0
      rt:spawn_raw(function()
        for _ = 1, n do
          total = total + rt:perform(operation)
        end
      end, 'minimal-scalar-reader')
      drain(rt)
      assert(total == n * 7)
      return rt
    end,
  },
  {
    name = 'scalar_write_prepared',
    operations = function(n)
      return n
    end,
    run = function(n, instrumented)
      local rt = runtime(instrumented)
      local scalar = Scalar.new(0, 'minimal-scalar-write-prepared')
      local operation = scalar:write_op(1)
      rt:spawn_raw(function()
        for _ = 1, n do
          rt:perform(operation)
        end
      end, 'minimal-scalar-writer-prepared')
      drain(rt)
      assert(scalar.value == 1)
      return rt
    end,
  },
  {
    name = 'scalar_write_dynamic',
    operations = function(n)
      return n
    end,
    run = function(n, instrumented)
      local rt = runtime(instrumented)
      local scalar = Scalar.new(0, 'minimal-scalar-write-dynamic')
      rt:spawn_raw(function()
        for i = 1, n do
          rt:perform(scalar:write_op(i))
        end
      end, 'minimal-scalar-writer-dynamic')
      drain(rt)
      assert(scalar.value == n)
      return rt
    end,
  },
  {
    name = 'ping_pong',
    operations = function(n)
      return n * 2
    end,
    run = function(n, instrumented)
      local rt = runtime(instrumented)
      local request = Rendezvous.new('minimal-ping')
      local reply = Rendezvous.new('minimal-pong')
      local total = 0
      rt:spawn_raw(function()
        for i = 1, n do
          rt:perform(request:put_op(i))
          total = total + rt:perform(reply:get_op())
        end
      end, 'minimal-client')
      rt:spawn_raw(function()
        for _ = 1, n do
          local value = rt:perform(request:get_op())
          rt:perform(reply:put_op(value))
        end
      end, 'minimal-server')
      drain(rt)
      assert(total == n * (n + 1) / 2)
      return rt
    end,
  },
}

local function median(values)
  table.sort(values)
  local n = #values
  if n % 2 == 1 then
    return values[(n + 1) / 2]
  end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

local function timed(case, n)
  case.run(math.max(1, math.floor(n / 20)), false)
  local samples = {}
  for i = 1, repeats do
    collectgarbage('collect')
    local started = Clock.now()
    case.run(n, false)
    samples[i] = Clock.now() - started
  end
  return median(samples)
end

local function allocated(case, n)
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count') * 1024
  local ok, value = pcall(case.run, n, false)
  local after = collectgarbage('count') * 1024
  collectgarbage('restart')
  collectgarbage('collect')
  if not ok then
    error(value, 0)
  end
  return after - before
end

local rows = {}
for i = 1, #cases do
  local case = cases[i]
  local ops = case.operations(iterations)
  local seconds = timed(case, iterations)
  local bytes = allocated(case, iterations)
  local diagnostic_rt = case.run(iterations, true)
  local counters = diagnostic_rt:instrumentation_snapshot().counters
  rows[#rows + 1] = {
    case = case.name,
    operations = ops,
    median_seconds = seconds,
    us_per_op = seconds * 1000000 / ops,
    bytes_per_op = bytes / ops,
    plans = counters.plans or 0,
    search_calls = counters.search_calls or 0,
    session_allocations = counters.search_session_allocations or 0,
    session_reuses = counters.search_session_reuses or 0,
  }
end

local lines = {}
if format == 'csv' then
  lines[#lines + 1] = 'case,operations,median_seconds,us_per_op,bytes_per_op,plans,'
    .. 'search_calls,session_allocations,session_reuses'
  for i = 1, #rows do
    local r = rows[i]
    lines[#lines + 1] = table.concat({
      r.case,
      r.operations,
      string.format('%.9f', r.median_seconds),
      string.format('%.6f', r.us_per_op),
      string.format('%.3f', r.bytes_per_op),
      r.plans,
      r.search_calls,
      r.session_allocations,
      r.session_reuses,
    }, ',')
  end
else
  lines[#lines + 1] = string.format(
    '%-14s %11s %12s %12s %8s %8s %10s',
    'case',
    'us/op',
    'bytes/op',
    'plans',
    'search',
    'sess new',
    'sess reuse'
  )
  for i = 1, #rows do
    local r = rows[i]
    lines[#lines + 1] = string.format(
      '%-14s %11.3f %12.1f %12d %8d %8d %10d',
      r.case,
      r.us_per_op,
      r.bytes_per_op,
      r.plans,
      r.search_calls,
      r.session_allocations,
      r.session_reuses
    )
  end
end

local text = table.concat(lines, '\n') .. '\n'
if output ~= '' then
  local file = assert(io.open(output, 'w'))
  file:write(text)
  file:close()
else
  io.write(text)
end
