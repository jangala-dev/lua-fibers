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

local fibers = require('fibers')
local file = require('fibers.file')
local Runtime = require('fibers.runtime')
local ManualHost = require('fibers.host.manual')

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local report = fibers.try_run(function(scope)
  -- Several live directions at once exercise indexed registration and service
  -- without turning this correctness test into a benchmark.
  local tasks = {}
  for i = 1, 3 do
    local reader, writer = file.pipe({
      name = 'reactor-stress-live-' .. tostring(i),
      capacity = 32,
      chunk_size = 7,
    })
    local payload = string.rep(string.char(64 + i), 13)
    tasks[#tasks + 1] = scope:spawn(function()
      writer:write(payload)
      writer:flush()
      writer:close('writer complete')
    end, 'reactor-stress-writer-' .. tostring(i))
    tasks[#tasks + 1] = scope:spawn(function()
      local got = reader:read('*a', { max = 32 })
      assert(got == payload, 'reactor stress payload mismatch')
      reader:close('reader complete')
    end, 'reactor-stress-reader-' .. tostring(i))
  end
  for i = 1, #tasks do
    tasks[i]:await()
  end

  -- Registration churn is tested separately from the live fan-out. This
  -- catches stale generations and incomplete retirement deterministically.
  for i = 1, 24 do
    local reader, writer = file.pipe({ name = 'reactor-stress-churn-' .. tostring(i) })
    writer:write('x')
    writer:close('churn writer complete')
    assert(reader:read('*a', { max = 2 }) == 'x')
    reader:close('churn reader complete')
    fibers.perform(fibers.sleep_op(0))
  end

  local rt = Runtime.current()
  local reactor = rt and rt.host_reactor
  assert_truthy(reactor, 'stress should have created a runtime reactor')
  fibers.perform(fibers.sleep_op(0))
  assert(reactor:registration_count() == 0, 'all stress registrations should retire')
end, {
  host = ManualHost.new({ pipes = true, auto_advance_time = true }),
  max_iterations = 20000,
})

assert_truthy(report.ok, 'reactor stress failed: ' .. tostring(report.primary))
print('tests/embedding/test_stream_reactor_stress.lua: ok')
