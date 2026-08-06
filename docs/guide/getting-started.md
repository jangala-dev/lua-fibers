# Getting started

This guide builds one small service from sequential fiber code into a composable and structured program.

For the complete public algebra, see [Options](options.md). For task and scope behaviour, see [Lifetimes](lifetimes.md).

## 1. Run a fiber

```lua
local fibers = require('fibers')

fibers.run(function()
  print('service started')
end)
```

`fibers.run` creates a Runtime and root scope, runs the body, accounts for retained work, then closes the Runtime.

## 2. Spawn structured work

```lua
local fibers = require('fibers')

fibers.run(function(scope)
  local task = scope:spawn(function()
    return load_configuration()
  end)

  local configuration = task:await()
  start_service(configuration)
end)
```

The task belongs to the current scope. The scope remains responsible for it until its complete Lifetime reaches an outcome.

`fibers.spawn(fn, opts)` is shorthand for spawning in the current scope.

## 3. Communicate through a channel

```lua
local fibers = require('fibers')
local channel = require('fibers.channel')

local commands = channel.new()
local results = channel.new()

fibers.run(function(scope)
  scope:spawn(function()
    while true do
      local command = commands:get()
      results:put(handle(command))
    end
  end)

  commands:put('refresh')
  print(results:get())
end)
```

The direct methods suspend only when a compatible participant is not presently available.

Use `channel.new(capacity)` for a bounded FIFO and `channel.new(math.huge)` for an unbounded FIFO.

## 4. Describe an action without performing it

Every direct channel action has an `_op` form:

```lua
local receive_command = commands:get_op()
local send_result = results:put_op('done')
```

These are options: inert descriptions which can be combined.

Perform one explicitly with:

```lua
local command = fibers.perform(receive_command)
```

The direct and option forms are equivalent:

```lua
commands:get()
-- is exactly
fibers.perform(commands:get_op())
```

## 5. Select an acceptable result

```lua
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')

local result = fibers.perform(Op.choice(
  results:get_op(),
  Sleep.sleep_op(5):map(function()
    return nil, 'deadline reached'
  end)
))
```

`choice` says that either coherent result is acceptable. Source order is not priority.

## 6. Sequence one transaction

Suppose the service has bounded capacity and should accept a request only when it can also publish it:

```lua
local Counter = require('fibers.resource.counter')

local capacity = Counter.bounded(16)

local admit = capacity:take_op(1)
  :and_then(commands:put_op('refresh'))

fibers.perform(admit)
```

The capacity change and communication commit together. If the command cannot be delivered, the capacity is not consumed.

When the next option depends on provisional values, use `Op.guard`:

```lua
local exchange = commands:get_op():and_then(
  Op.guard(function(command)
    return results:put_op(handle(command))
  end)
)
```

## 7. Fall back without waiting

```lua
local next_command = commands:get_op()
  :or_else(Op.always('idle'))

local command = fibers.perform(next_command)
```

The fallback is considered when the preferred action cannot happen now. “Now” includes every coherent transaction which can commit without a future change, not merely one local readiness check.

A timeout remains an ordinary choice with a timer. `or_else` is not a timer.

## 8. Combine several requirements

Use `each` when every lane must stand on its own:

```lua
local reservations = fibers.perform(Op.each({
  cpu_slots:take_op(1),
  network_slots:take_op(1),
}))
```

Use `together` when compatible lanes may deliberately support one another:

```lua
fibers.perform(Op.together({
  flow:inlet():write_op('GO'),
  flow:outlet():read_some_op(2),
}))
```

Products return one nil-preserving packed row per lane. See [Product results](options.md#product-results).

## 9. Handle task failure through the scope

The root scope is a nursery. If a child task fails, the boundary fails, requests closure of remaining siblings and accounts for retained work before returning.

```lua
local result = fibers.try_run(function(scope)
  scope:spawn(function()
    error('worker failed')
  end)

  wait_for_shutdown()
end)

if not result.ok then
  print(result:tostring())
end
```

Use a supervisor scope when child failures should be collected or handled under another explicit policy. See [Lifetimes](lifetimes.md).

## 10. Add labels when observation needs them

Labels are optional diagnostic metadata, not part of correct construction:

```lua
local commands = channel.new(16)
  :label('service-commands')

local worker = fibers.spawn(run_worker)
  :label('configuration-watcher')
```

Options may also be labelled without changing their meaning:

```lua
local next_event = Op.choice(
  commands:get_op():label('receive-command'),
  shutdown:get_op():label('receive-shutdown')
):label('select-service-event')
```

See [Execution and observability](../advanced/execution-and-observability.md).

## 11. Assert a coordinator reduction does not suspend

```lua
while true do
  local event = fibers.perform(next_event_op(state))

  fibers.without_suspension(function()
    reduce_event(state, event)
  end)
end
```

The region may perform operations which commit immediately. It fails before the current fiber is parked or another application fiber is allowed to run first.

## 12. Use host-backed I/O

Host facilities use the same option and lifetime model:

```lua
local file = require('fibers.file')
local AutoIO = require('fibers.io.auto')

fibers.run(function()
  local contents = assert(file.read_all('/etc/resolv.conf', {
    max = 64 * 1024,
  }))

  print(contents)
end, {
  host = AutoIO.default(),
})
```

Open files, Streams, Processes, Listeners, Dials and datagram sockets are retained under Lifetime custody until moved or closed.

See [Files, pipes, processes and sockets](io.md).

## Next steps

- [Options](options.md)
- [Lifetimes](lifetimes.md)
- [Resources](resources.md)
- [API reference](../api-reference.md)
- [Runnable examples](../../examples/README.md)
