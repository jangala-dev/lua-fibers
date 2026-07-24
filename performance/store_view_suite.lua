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
local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local Clock = require('performance.clock')

local cells = tonumber(os.getenv('FIBERS_STORE_CELLS') or '16')
local lanes = tonumber(os.getenv('FIBERS_STORE_LANES') or '16')
local rounds = tonumber(os.getenv('FIBERS_STORE_ROUNDS') or '200')
local repeats = tonumber(os.getenv('FIBERS_STORE_REPEATS') or '5')

local function median(values)
  table.sort(values)
  local n = #values
  if n % 2 == 1 then
    return values[(n + 1) / 2]
  end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

local function build_case()
  local rt = Runtime.new()
  local scalars, reads = {}, {}
  for i = 1, cells do
    scalars[i] = Scalar.new(i, 'store-view-cell-' .. tostring(i))
    reads[i] = scalars[i]:read_op()
  end

  local lane_ops = {}
  for i = 1, lanes do
    lane_ops[i] = Op.always(i)
  end
  local product = Op.all(lane_ops)
  local operation = Op.always(true)
  for i = 1, cells do
    local read = reads[i]
    local dependencies = Op.dependencies(read)
    operation = operation:and_then(function()
      return read
    end, dependencies)
  end
  operation = operation:and_then(function()
    return product
  end, Op.dependencies(product))

  local total = 0
  rt:spawn_raw(function()
    for _ = 1, rounds do
      local rows = rt:perform(operation)
      total = total + #rows
    end
  end, 'store-view-benchmark')

  return rt, function()
    assert(total == rounds * lanes, 'store-view benchmark result mismatch')
  end
end

local times, allocations = {}, {}
for _ = 1, repeats do
  collectgarbage('collect')
  local rt, validate = build_case()
  collectgarbage('collect')
  local before = collectgarbage('count')
  collectgarbage('stop')
  local started = Clock.now()
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  local elapsed = Clock.now() - started
  local after = collectgarbage('count')
  collectgarbage('restart')
  assert(status.tag == 'idle' or status.tag == 'quiescent', 'runtime did not drain')
  validate()
  times[#times + 1] = elapsed * 1e6 / rounds
  allocations[#allocations + 1] = (after - before) * 1024 / rounds
end

io.write('clock,cells,lanes,rounds,repeats,median_us_per_round,median_bytes_per_round\n')
io.write(
  string.format(
    '%s,%d,%d,%d,%d,%.6f,%.3f\n',
    Clock.name,
    cells,
    lanes,
    rounds,
    repeats,
    median(times),
    median(allocations)
  )
)
