# Programming guide

Fibers presents a small application-facing concurrency language. Options describe possible actions; `perform` is the single execution boundary.

```lua
local fibers = require('fibers')
local channel = require('fibers.channel')
local Scalar = require('fibers.scalar')
local Pulse = require('fibers.pulse')
local Mailbox = require('fibers.mailbox')
local Stream = require('fibers.stream')
```

Import only the facilities a programme uses. Runtime embedding, host adapters, transactional resource materials and lifetime machinery live in their own named modules.

## Run, spawn and perform

Most programmes begin with `fibers.run`:

```lua
fibers.run(function(scope)
  local task = scope:spawn(function()
    return 'done'
  end, 'worker')

  assert(fibers.perform(task:await_op()) == 'done')
end)
```

`fibers.run` creates a runtime, a root scope and a standalone runner. `fibers.spawn` is shorthand for spawning in the current scope.

```lua
fibers.run(function()
  local task = fibers.spawn(function()
    return 7
  end)
  assert(fibers.perform(task:await_op()) == 7)
end)
```

Nested scopes use `fibers.scope`. The raising forms `run` and `scope` return body values or raise after the boundary has accounted for retained custody. `try_run` and `try_scope` return a `ScopeResult`.

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

## Options

An option is an inert transaction description. Constructing one does not perform it.

The API type is named `Op`, short for **option**, and resource methods ending in `_op` construct options. The suffix does not mean operation.

```lua
local op = fibers.always(42)
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

`map`, `and_then` and resource transition callbacks execute during speculative proof search and may be replayed. They must be deterministic, non-yielding and free of irreversible side effects. `wrap` runs for the resumed participant after commit and may perform another option.

### Choice

`choice` is unordered disjunction:

```lua
local value = fibers.perform(fibers.choice(
  left:get_op(),
  right:get_op()
))
```

If both branches can commit, either result is valid. Source position does not give a branch priority.

A timeout is ordinary choice:

```lua
local result = fibers.perform(fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1):wrap(function()
    return 'timeout'
  end)
))
```

`or_else` provides validated immediate fallback. Its fallback is eligible only after the preferred option has been completely refuted under recorded managed facts.

```lua
local value = fibers.perform(
  cache:get_op(key):or_else(fibers.always(default_value))
)
```

### Products

`all` combines independent requirements in one commit:

```lua
local rows = fibers.perform(fibers.all({
  left:take_op(1),
  right:take_op(1),
}))
```

`tensor` additionally permits compatible sibling hand-off:

```lua
fibers.perform(fibers.tensor({
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
    fibers.perform(inbox:put_op('hello'))
  end)

  assert(fibers.perform(inbox:get_op()) == 'hello')
end)
```

The lower-level synchronous exchange resource remains available as `fibers.resource.rendezvous` for facilities which need its exact law.

## Transactional state

Use `Scalar` for one replaceable fact:

```lua
local state = Scalar.new({ open = true, count = 0 }, 'state')

local increment = state:read_op():and_then(function(old)
  if not old.open then
    return fibers.never()
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

fibers.perform(pulse:signal_op())
fibers.perform(tx:send_op('message'))
assert(fibers.perform(rx:recv_op()) == 'message')
```

## Streams

`Stream` is the supported bidirectional byte facility. The current flow implementation is private and may change without altering the Stream contract.

```lua
local a, b = Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
assert(fibers.perform(b:reader():read_line_op()) == 'hello')
```

Host-backed streams are opened transactionally:

```lua
local stream = fibers.perform(Stream.open_backend_op(backend, {
  name = 'connection',
}))
```

If the open option loses, no pump starts. See `../advanced/embedding.md` for backend and host-handle contracts.

## Time

Application code normally sleeps through options:

```lua
fibers.perform(fibers.sleep_op(0.25))
```

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
fibers.external.signal
fibers.external.event_queue
fibers.external.clock
fibers.external.readiness
```

See `../advanced/facility-authoring.md` and `../../examples/recipes/` for complete facilities built only from supported interfaces.

Petri and Calendar are trusted kernel case studies under `examples/case_studies/`. They are not installed modules or version 1 API commitments. Phase and the current scalar Flow work remain under `experiments/`.

## Further reading

- `../advanced/option-algebra.md` — option semantics and laws
- `../advanced/lifetimes-and-custody.md` — custody, borrowing, claims and policy
- `../advanced/embedding.md` — direct runtime driving and hosts
- `../advanced/facility-authoring.md` — composing supported public facilities
- `../contributing/trusted-resource-programmes.md` — closed kernel resource programmes
- `../design/kernel.md` — kernel representation and execution
