# Programming guide

Fibers presents a small application-facing concurrency language. Direct methods provide a gentle sequential surface; `_op` methods expose the same actions as inert options for composition.

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local Scalar = require('fibers.resource.scalar')
local Pulse = require('fibers.pulse')
local Mailbox = require('fibers.mailbox')
local Stream = require('fibers.stream')
```

Import only the facilities a programme uses. Runtime embedding, host adapters, transactional resource materials and custody machinery live in their own named modules.

## Run, spawn and perform

Most programmes begin with `fibers.run`:

```lua
fibers.run(function(scope)
  local task = scope:spawn(function()
    return 'done'
  end, 'worker')

  assert(task:await() == 'done')
end)
```

`fibers.run` creates a runtime and root scope, then drives them through the selected host. `fibers.spawn` is shorthand for spawning in the current scope.

```lua
fibers.run(function()
  local task = fibers.spawn(function()
    return 7
  end)
  assert(task:await() == 7)
end)
```

Nested scopes use `fibers.scope`. The raising forms `fibers.run` and `fibers.scope` return body values or raise after the boundary has accounted for retained custody. `fibers.try_run` and `fibers.try_scope` return a `ScopeResult`.

```lua
local outcome = fibers.try_scope(function()
  return 'ok'
end)

if outcome.ok then
  assert(outcome:unpack() == 'ok')
else
  print(outcome:tostring())
end
```

## Direct methods and options

Selected everyday facilities expose both forms:

```lua
local message = inbox:get()
```

is exactly:

```lua
local message = fibers.perform(inbox:get_op())
```

Use direct methods for ordinary sequential code. Use `_op` when an action must
participate in `choice`, `or_else`, `and_then`, `all` or `tensor`. The detailed
policy is in [`direct-and-options.md`](direct-and-options.md).

## Options

An option is an inert transaction description. Constructing one does not perform it.

An `Op` can be thought of as an option: an inert transaction description. Resource methods ending in `_op` construct these values.

```lua
local op = Op.always(42)
assert(fibers.perform(op) == 42)
```

The principal combinators are:

```text
op:map(function(...) ... end)
op:and_then(function(...) return another_op end)
op:or_else(fallback_op)
op:wrap(function(...) ... end)
op:on_defeat(effect)
```

Fibers has three callback phases. Search callbacks such as `guard`, `map`, `and_then`, resource transitions and effect keying are speculative and replayable. Effect `prepare` is also pure and replayable; it returns a discharge plan but must not reserve, mutate, spawn, perform or yield. Effect `discharge` runs after state commits. `wrap` then runs for the resumed participant and may perform another option. These rules are normative; see `../advanced/option-algebra.md`.

### Choice

`choice` is unordered disjunction:

```lua
local value = fibers.perform(Op.choice(
  left:get_op(),
  right:get_op()
))
```

If both branches can commit, either result is valid. Source position does not give a branch priority.

A timeout is ordinary choice:

```lua
local result = fibers.perform(Op.choice(
  inbox:get_op(),
  Sleep.sleep_op(1):wrap(function()
    return 'timeout'
  end)
))
```

`or_else` provides validated immediate fallback. Its fallback is eligible only after the preferred option has been completely refuted under recorded managed facts.

```lua
local value = fibers.perform(
  cache:get_op(key):or_else(Op.always(default_value))
)
```

### Products

`all` combines independent requirements in one commit:

```lua
local rows = fibers.perform(Op.all({
  left:take_op(1),
  right:take_op(1),
}))
```

`tensor` additionally permits compatible sibling hand-off:

```lua
fibers.perform(Op.tensor({
  slots:give_op(1),
  slots:take_op(1),
}))
```

Use `all` when each lane must be satisfiable without positive supply from its siblings. Use `tensor` when lanes intentionally communicate or transfer transactional stock.

## Channels

Channel is the ordinary communication facility:

```lua
local inbox = channel.new()       -- synchronous
local buffered = channel.new(16) -- bounded FIFO
```

Both forms expose `put_op` and `get_op`.

```lua
fibers.run(function()
  fibers.spawn(function()
    inbox:put('hello')
  end)

  assert(inbox:get() == 'hello')
end)
```

The lower-level synchronous exchange resource remains available as `fibers.resource.rendezvous` for facilities which need its exact law.

## Transactional state

Use `Scalar` for one replaceable fact:

```lua
local state = Scalar.new({ open = true, count = 0 }, 'state')

local increment = state:read_op():and_then(function(old)
  if not old.open then
    return Op.never()
  end
  return state:write_op({ open = true, count = old.count + 1 })
end)

fibers.perform(increment)
```

For an ordered state machine, define a typed transition:

```lua
local Increment = Scalar.transition({
  name = 'counter.increment',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  validate = function(payload)
    assert(type(payload.by) == 'number', 'by must be a number')
  end,
  step = function(value, payload)
    local next_value = value + payload.by
    return Scalar.Ready.write(next_value, next_value)
  end,
})

local counter = Scalar.machine(0, 'counter')
local next_value = fibers.perform(counter:transition_op(Increment, { by = 1 }))
assert(next_value == 1)
```

## Notification and messaging

`Pulse` represents coalescing change notification. `Mailbox` provides split sender and receiver endpoints, closure and selectable overflow policies. Both expose options and compose with the same choice and product vocabulary.

```lua
local pulse = Pulse.new()
local tx, rx = Mailbox.new(16)

pulse:signal()
tx:send('message')
assert(rx:recv() == 'message')
```

## Flows and streams

`Flow` is the supported transactional byte-building block. It provides stable producer and consumer endpoints, backpressure, exact byte reads, closure and retained-byte leases.

```lua
local Flow = require('fibers.resource.flow')
local flow = Flow.new({ capacity = 4096 })

flow:inlet():write('hello\n')
assert(flow:outlet():read_line() == 'hello')
```

`Stream` is the familiar readable, writable or duplex facility built from one or two Flows:

```lua
local a, b = Stream.memory_pair({ capacity = 4096 })

a:write('hello\n')
assert(b:read_line() == 'hello')
```

Host-backed streams are opened transactionally:

```lua
local stream = fibers.perform(Stream.open_op(handle, {
  name = 'connection',
  read = true,
  write = true,
}))
```

All host-backed stream directions in one Runtime share one lazily created reactor. If the open option loses, no registration is discharged and no reactor starts. See `../advanced/flows-and-streams.md` and `../advanced/embedding.md`.

## Time

Application code may use the direct form:

```lua
Sleep.sleep(0.25)
```

The composable form remains `Sleep.sleep_op(0.25)`.

The relative deadline is fixed once per perform attempt; validation restart does not slide it forwards.

## Scopes, cancellation and settlement

Most lifetime-bearing values should be created or admitted inside a scope:

```lua
fibers.scope(function(scope)
  local task = scope:spawn(function()
    return 'ok'
  end)

  assert(fibers.perform(task:await_op()) == 'ok')
end)
```

The public application vocabulary remains small. Advanced custody, borrowing, settlement and policy interfaces are described in `../advanced/lifetimes-and-custody.md`.

## Protected calls

Use `fibers.pcall` and `fibers.xpcall` when protected code may suspend:

```lua
local ok, value = fibers.pcall(function()
  return fibers.perform(op)
end)
```

These helpers provide yieldable protection on Lua 5.1 as well as later versions.

## Resource toolkit, recipes and case studies

Facility authors can compose the supported resource toolkit:

```text
fibers.resource.rendezvous
fibers.resource.counter
fibers.resource.index
fibers.resource.keyed
fibers.resource.lease
fibers.resource.signal
fibers.resource.event_queue
fibers.resource.clock
fibers.host.readiness
```

See `../advanced/facility-authoring.md` and `../../examples/recipes/` for complete facilities built only from supported interfaces.

Petri and Calendar are trusted kernel case studies under `examples/case_studies/`. They are not installed modules or version 1 API commitments. Phase remains a work-in-progress prototype under `docs/notes/`.

## Further reading

- `direct-and-options.md` — direct methods and composable options
- `../advanced/option-algebra.md` — option semantics and laws
- `../advanced/lifetimes-and-custody.md` — custody, borrowing, claims and policy
- `../advanced/flows-and-streams.md` — Flow leases, Streams and the shared reactor
- `../advanced/embedding.md` — direct runtime driving and hosts
- `../advanced/facility-authoring.md` — composing supported public facilities
- `../contributing/trusted-resource-programmes.md` — closed kernel resource programmes
- `../design/kernel.md` — kernel representation and execution
