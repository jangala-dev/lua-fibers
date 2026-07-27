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
local StateMachine = require('fibers.resource.machine')
local FibersChannel = require('fibers.channel')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersStream = require('fibers.stream')
local FibersCalendar = require('examples.case_studies.calendar.calendar')
local FibersPetri = require('examples.case_studies.petri.petri')
local FibersHost = require('fibers.host')
local FibersOp = require('fibers.op')
local FibersLifetime = require('fibers.lifetime')
local FibersScope = require('fibers.scope')

-- README generic command and structured scope.
fibers.run(function(scope)
  local commands = FibersChannel.new()
  local results = FibersChannel.new()

  scope:spawn(function()
    local command = commands:get()
    results:put('completed ' .. command)
  end, 'command-worker')

  commands:put('refresh configuration')
  assert(results:get() == 'completed refresh configuration')
end)

-- Programming-guide Machine transition.
fibers.run(function()
  local Increment = StateMachine.update(
    'counter.increment',
    function(value, payload)
      local next_value = value + payload.by
      return StateMachine.Ready.write(next_value, next_value)
    end,
    nil,
    function(payload)
      assert(type(payload.by) == 'number', 'by must be a number')
    end
  )

  local counter = StateMachine.new(0, 'counter')
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

-- Lifetime guide: custody, Grants and Closure use the ordinary Op algebra.
fibers.run(function(source)
  local worker = FibersScope.new('documented-grant-worker', {
    runtime = source.runtime,
  })
  local resource = { name = 'documented-resource' }
  FibersLifetime.inert(resource, { rights = { read = true } })

  fibers.perform(source:admit_op(resource))
  local grant = fibers.perform(source:grant_op(resource, worker, { 'read' }))
  local authorised = fibers.perform(worker:can_op(resource, 'read'))
  assert(authorised == resource)

  fibers.perform(worker:close_op(grant, 'example complete'))
  local after_close = fibers.perform(worker
    :can_op(resource, 'read')
    :map(function()
      return true
    end)
    :or_else(FibersOp.always(false)))
  assert(after_close == false)

  fibers.perform(source:move_op(resource, worker))
  assert(fibers.perform(worker:has_custody_op(resource)) == true)
  fibers.perform(worker:close_op(resource, 'example complete'))
end)

print('examples/test_documented_examples.lua: ok')
