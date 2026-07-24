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
  local configuration_task = scope:spawn(function()
    return 'configuration loaded'
  end, 'load-configuration')

  assert(configuration_task:await() == 'configuration loaded')
end)
```

`fibers.run` creates a runtime and root scope, then drives them through the selected host. `fibers.spawn` is shorthand for spawning in the current scope.

```lua
fibers.run(function()
  local cache_task = fibers.spawn(function()
    return 'cache warm'
  end)
  assert(cache_task:await() == 'cache warm')
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
local update = status_updates:get()
```

is exactly:

```lua
local update = fibers.perform(status_updates:get_op())
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
local selected = fibers.perform(Op.choice(
  scene_finished:get_op(),
  skip_requested:get_op()
))
```

If both branches can commit, either result is valid. Source position does not give a branch priority.

A timeout is ordinary choice:

```lua
local result = fibers.perform(Op.choice(
  voice_lines:get_op(),
  Sleep.sleep_op(1):wrap(function()
    return '[continue with subtitles]'
  end)
))
```

`or_else` provides validated immediate fallback. Its fallback is eligible only after the preferred option has been completely refuted under recorded managed facts.

```lua
local intention = fibers.perform(
  attack_op(agent, target)
    :or_else(take_cover_op(agent))
    :or_else(return_to_patrol_op(agent))
)
```

### Products

`all` combines independent requirements in one commit:

```lua
local reservations = fibers.perform(Op.all({
  camera_channels:take_op(1),
  animation_channels:take_op(1),
}))
```

`tensor` additionally permits compatible sibling hand-off:

```lua
fibers.perform(Op.tensor({
  cue_bus:inlet():write_op('GO'),
  cue_bus:outlet():read_some_op(2),
}))
```

Use `all` when each lane must be satisfiable without positive supply from its siblings. Use `tensor` when lanes intentionally communicate or transfer transactional stock.

## Channels

Channel is the ordinary communication facility:

```lua
local commands = channel.new()          -- synchronous
local buffered_events = channel.new(16) -- bounded FIFO
```

Both forms expose `put_op` and `get_op`.

```lua
fibers.run(function()
  fibers.spawn(function()
    commands:put('refresh configuration')
  end)

  assert(commands:get() == 'refresh configuration')
end)
```

The lower-level synchronous exchange resource remains available as `fibers.resource.rendezvous` for facilities which need its exact law.

## Transactional state

Use `Scalar` for one replaceable fact:

```lua
local quest = Scalar.new({ stage = 'find_key', clues = 1 }, 'moon-gate-quest')

local advance = quest:read_op():and_then(function(current)
  if current.stage ~= 'find_key' or current.clues < 1 then
    return Op.never()
  end
  return quest:write_op({ stage = 'open_gate', clues = current.clues })
end)

fibers.perform(advance)
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
local weather_changed = Pulse.new()
local combat_tx, combat_rx = Mailbox.new(16)

weather_changed:signal()
combat_tx:send('perfect parry')
assert(combat_rx:recv() == 'perfect parry')
```

## Flows and streams

`Flow` is the supported transactional byte-building block. It provides stable producer and consumer endpoints, backpressure, exact byte reads, closure and retained-byte leases.

```lua
local Flow = require('fibers.resource.flow')
local dialogue_flow = Flow.new({ capacity = 4096 })

dialogue_flow:inlet():write('The gate is open.\n')
assert(dialogue_flow:outlet():read_line() == 'The gate is open.')
```

`Stream` is the familiar readable, writable or duplex facility built from one or two Flows:

```lua
local narrator, subtitles = Stream.memory_pair({ capacity = 4096 })

narrator:write('The gate is open.\n')
assert(subtitles:read_line() == 'The gate is open.')
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
- `roblox.md` — step-by-step game logic, scene lifetimes and Roblox host architecture
- `../advanced/option-algebra.md` — option semantics and laws
- `../advanced/lifetimes-and-custody.md` — custody, borrowing, claims and policy
- `../advanced/flows-and-streams.md` — Flow leases, Streams and the shared reactor
- `../advanced/embedding.md` — direct runtime driving and hosts
- `../advanced/facility-authoring.md` — composing supported public facilities
- `../contributing/trusted-resource-programmes.md` — closed kernel resource programmes
- `../design/kernel.md` — kernel representation and execution
