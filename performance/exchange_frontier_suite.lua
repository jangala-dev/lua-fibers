-- Focused regression measurements for demand-directed participant recruitment
-- and closed exchange-frontier matching.

package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')

local output = os.getenv('FIBERS_EXCHANGE_FRONTIER_OUTPUT') or ''
local rows = {}

local function exchange_lanes(channel, puts, gets)
  local lanes = {}
  for _ = 1, puts do lanes[#lanes + 1] = channel:put_op(true) end
  for _ = 1, gets do lanes[#lanes + 1] = channel:get_op() end
  return lanes
end

local function measure(name, scale, build, expected)
  collectgarbage('collect')
  collectgarbage('collect')
  local runtime, result = build()
  local started = os.clock()
  local status = runtime:run()
  local seconds = os.clock() - started
  local report = runtime.instrumentation:report()
  if status.tag ~= 'found' then
    error(name .. ' did not complete: ' .. tostring(status.tag) .. '/' .. tostring(status.reason), 2)
  end
  local value = result()
  if value ~= expected then
    error(name .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(value), 2)
  end
  rows[#rows + 1] = {
    case = name,
    scale = scale,
    result = value,
    status = status.tag,
    seconds = seconds,
    searches = report.counters.searches or 0,
    search_calls = report.counters.search_calls or 0,
    max_search_steps = report.maxima.search_steps_per_search or 0,
    max_component = report.maxima.component_size or 0,
  }
end

measure('failing_suppliers', 64, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 256 })
  local channel = Rendezvous.new():label('frontier-perf-suppliers')
  for i = 1, 64 do
    runtime:spawn_raw(function()
      runtime:perform(channel:get_op():and_then(Op.never()))
    end):label('supplier-' .. i)
  end
  local result
  runtime:spawn_raw(function()
    result = runtime:perform(channel:put_op(true):or_else(Op.always('fallback')))
  end):label('focus')
  return runtime, function() return result end
end, 'fallback')

measure('role_imbalance', 64, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 64 })
  local channel = Rendezvous.new():label('frontier-perf-imbalance')
  local result
  runtime:spawn_raw(function()
    result = runtime:perform(
      Op.together(exchange_lanes(channel, 64, 65)):or_else(Op.always('fallback'))
    )
  end):label('focus')
  return runtime, function() return result end
end, 'fallback')

measure('hall_deficient', 64, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 64 })
  local channel = Rendezvous.new():label('frontier-perf-hall')
  runtime:spawn_raw(function()
    runtime:perform(Op.each(exchange_lanes(channel, 63, 64)))
  end):label('root-b')
  local result
  runtime:spawn_raw(function()
    local preferred = Op.each(exchange_lanes(channel, 65, 64))
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('root-a')
  return runtime, function() return result end
end, 'fallback')

measure('perfect_constrained', 64, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 64 })
  local channel = Rendezvous.new():label('frontier-perf-perfect')
  runtime:spawn_raw(function()
    runtime:perform(Op.each(exchange_lanes(channel, 64, 64)))
  end):label('root-b')
  local result
  runtime:spawn_raw(function()
    local preferred = Op.each(exchange_lanes(channel, 64, 64)):map(function() return 'preferred' end)
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('root-a')
  return runtime, function() return result end
end, 'preferred')

measure('complete_internal', 128, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 64 })
  local channel = Rendezvous.new():label('frontier-perf-complete')
  local result
  runtime:spawn_raw(function()
    result = runtime:perform(Op.together(exchange_lanes(channel, 128, 128)):map(function() return 'preferred' end))
  end):label('focus')
  return runtime, function() return result end
end, 'preferred')

measure('failing_supplier_chain', 64, function()
  local runtime = Runtime.new({ quiet_deadlock = true, instrumentation = true, search_total_limit = 256 })
  local channels = {}
  for i = 1, 64 do channels[i] = Rendezvous.new():label('frontier-perf-chain-' .. i) end
  for i = 1, 64 do
    local index = i
    runtime:spawn_raw(function()
      local supplier = channels[index]:get_op()
      if index < 64 then
        supplier = supplier:and_then(channels[index + 1]:put_op(index))
      else
        supplier = supplier:and_then(Op.never())
      end
      runtime:perform(supplier)
    end):label('supplier-' .. i)
  end
  local result
  runtime:spawn_raw(function()
    result = runtime:perform(channels[1]:put_op(0):or_else(Op.always('fallback')))
  end):label('focus')
  return runtime, function() return result end
end, 'fallback')

local headers = {
  'case', 'scale', 'result', 'status', 'seconds',
  'searches', 'search_calls', 'max_search_steps', 'max_component',
}
local lines = { table.concat(headers, ',') }
for i = 1, #rows do
  local values = {}
  for j = 1, #headers do
    local value = rows[i][headers[j]]
    if headers[j] == 'seconds' then value = string.format('%.6f', value) end
    values[j] = tostring(value)
  end
  lines[#lines + 1] = table.concat(values, ',')
end
local text = table.concat(lines, '\n') .. '\n'
if output ~= '' then
  local file = assert(io.open(output, 'wb'))
  file:write(text)
  file:close()
else
  io.write(text)
end
