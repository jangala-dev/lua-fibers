package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Counter = require('fibers.resource.counter')
local Latch = require('fibers.latch')
local Pulse = require('fibers.pulse')
local Semaphore = require('fibers.semaphore')

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'not equal') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

local function found(status)
  eq(status and status.tag, 'found', 'runtime status')
end

local function run(body)
  local runtime = Runtime.new()
  runtime:spawn_raw(function()
    body(runtime)
  end):label('test')
  found(runtime:run())
end

local function test_counter_directional_waits()
  local counter = Counter.new(1):label('directional-counter')
  local rows

  run(function(runtime)
    rows = runtime:perform(Op.together({
      counter:take_op(),
      counter:zero_op(),
    }))
  end)

  eq(rows[1][1], true)
  eq(rows[2][1], 0)
  eq(counter._location.value, 0)
end

local function test_latch_is_set_once()
  local latch = Latch.new():label('latch')
  local before, first, after, second, value

  run(function(runtime)
    before = runtime:perform(latch:is_set_op())
    first = runtime:perform(latch:set_op('ready'))
    after = runtime:perform(latch:is_set_op())
    second = runtime:perform(latch:set_op('ignored'))
    value = runtime:perform(latch:get_op())
  end)

  eq(before, false)
  eq(first, true)
  eq(after, true)
  eq(second, false)
  eq(value, 'ready')
end

local function test_pulse_is_counter_plus_close_state()
  local pulse = Pulse.new(0):label('pulse')
  local rows, ended, reason, version

  run(function(runtime)
    rows = runtime:perform(Op.together({
      pulse:signal_op(),
      pulse:changed_op(0),
    }))
    runtime:perform(pulse:close_op('done'))
    ended, reason = runtime:perform(pulse:changed_op(rows[2][1]))
    runtime:perform(pulse:signal_op())
    version = runtime:perform(pulse:version_op())
  end)

  eq(rows[1][1], 1)
  eq(rows[2][1], 1)
  eq(ended, nil)
  eq(reason, 'done')
  eq(version, 1)
end

local function test_semaphore_is_bounded_counter_vocabulary()
  local semaphore = Semaphore.new(2):label('semaphore')
  local available

  run(function(runtime)
    runtime:perform(semaphore:acquire_op(2))
    runtime:perform(Op.together({
      semaphore:release_op(),
      semaphore:acquire_op(),
    }))
    available = runtime:perform(semaphore:available_op())
  end)

  eq(available, 0)
end

local tests = {
  test_counter_directional_waits,
  test_latch_is_set_once,
  test_pulse_is_counter_plus_close_state,
  test_semaphore_is_bounded_counter_vocabulary,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/resources/test_standard_compounds.lua: ok')
