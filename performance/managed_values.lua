package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local Machine = require('fibers.resource.machine')
local Ready = Machine.Ready

local iterations = tonumber(arg and arg[1]) or 5000
local repetitions = tonumber(arg and arg[2]) or 5

local ScalarIncrement = Machine.isolated_update('bench.scalar-increment', function(value)
  return Ready.write(value + 1)
end)

local TableIncrement = Machine.isolated_update('bench.table-increment', function(state)
  return Ready.write({
    count = state.count + 1,
    nested = { flag = state.nested.flag },
  })
end)

local function measure(name, make, step)
  for run = 1, repetitions do
    collectgarbage('collect')
    local before = collectgarbage('count')
    local rt = Runtime.new()
    local resource = make()
    local checksum = 0
    rt:spawn_raw(function()
      for i = 1, iterations do
        checksum = checksum + step(rt, resource, i)
      end
    end)
    local start = os.clock()
    local status = rt:run()
    local elapsed = os.clock() - start
    assert(status.tag == 'found')
    local heap = collectgarbage('count') - before
    print(string.format(
      '%-14s run=%d n=%d seconds=%.6f us_per_pair=%.2f heap_delta_kb=%.1f checksum=%d',
      name,
      run,
      iterations,
      elapsed,
      elapsed * 1000000 / iterations,
      heap,
      checksum
    ))
  end
end

measure('cell-scalar', function()
  return Cell.new(0)
end, function(rt, cell, i)
  rt:perform(cell:write_op(i))
  return rt:perform(cell:read_op())
end)

measure('cell-table', function()
  return Cell.new({ count = 0, nested = { flag = true } })
end, function(rt, cell, i)
  rt:perform(cell:write_op({ count = i, nested = { flag = i % 2 == 0 } }))
  return rt:perform(cell:read_op()).count
end)

measure('machine-scalar', function()
  return Machine.new(0)
end, function(rt, machine)
  rt:perform(machine:transition_op(ScalarIncrement))
  return rt:perform(machine:read_op())
end)

measure('machine-table', function()
  return Machine.new({ count = 0, nested = { flag = true } })
end, function(rt, machine)
  rt:perform(machine:transition_op(TableIncrement))
  return rt:perform(machine:read_op()).count
end)
