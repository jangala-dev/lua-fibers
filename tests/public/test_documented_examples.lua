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
local FibersRuntime = require('fibers.runtime')
local FibersScalar = require('fibers.scalar')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersStream = require('fibers.stream')
local FibersCalendar = require('examples.case_studies.calendar.calendar')
local FibersPetri = require('examples.case_studies.petri.petri')
local FibersHost = require('fibers.host')

-- README rendezvous and structured scope.
fibers.run(function(scope)
  local inbox = FibersRendezvous.new('docs-inbox')
  scope:spawn(function()
    fibers.perform(inbox:put_op('hello'))
  end, 'sender')
  assert(fibers.perform(inbox:get_op()) == 'hello')
end)

-- Programming-guide Scalar transition.
fibers.run(function()
  local Increment = FibersScalar.transition({
    name = 'counter.increment',
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    validate = function(payload)
      assert(type(payload.by) == 'number', 'by must be a number')
    end,
    step = function(value, payload)
      local next_value = value + payload.by
      return FibersScalar.Ready.write(next_value, next_value)
    end,
  })

  local counter = FibersScalar.machine(0, 'counter')
  assert(fibers.perform(counter:transition_op(Increment, { by = 1 })) == 1)
end)

-- Programming-guide Petri transition.
fibers.run(function()
  local net = FibersPetri.new({
    jobs = { { id = 1, priority = 10 } },
    workers = { 'alice' },
  })

  local start = net:transition({
    name = 'start',
    inputs = {
      { place = 'jobs', as = 'job' },
      { place = 'workers', as = 'worker' },
    },
    produce = function(binding)
      return {
        running = {
          { job = binding.job, worker = binding.worker },
        },
      }
    end,
    result = function(binding)
      return binding.job, binding.worker
    end,
  })

  local job, worker = fibers.perform(net:fire_op(start))
  assert(job.id == 1 and worker == 'alice')
end)

-- Programming-guide Calendar reservation.
fibers.run(function()
  local calendar = FibersCalendar.new()
  local booking = fibers.perform(calendar:reserve_op({
    resources = { 'room-a', 'alice' },
    earliest = 9,
    latest = 17,
    duration = 1,
    preference = 'earliest',
    payload = { purpose = 'review' },
  }))

  assert(booking.start == 9 and booking.finish == 10)
  assert(fibers.perform(calendar:cancel_op(booking.id)).id == booking.id)
end)

-- External feeds are driver actions, not fibre actions.
do
  local rt = FibersRuntime.new({ host = FibersHost.manual() })
  local signal, feed = rt:signal('shutdown')
  local result

  rt:spawn_raw(function()
    result = rt:perform(signal:wait_op())
  end, 'waiter')

  rt:run()
  feed:set('requested')
  rt:run()
  assert(result == 'requested')
end

-- README Stream example.
fibers.run(function()
  local a, b = FibersStream.memory_pair({ capacity = 4096 })
  fibers.perform(a:writer():write_op('hello\n'))
  assert(fibers.perform(b:reader():read_line_op()) == 'hello')
end)

print('tests/test_documented_examples.lua: ok')
