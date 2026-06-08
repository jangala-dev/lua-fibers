# fibers

`fibers` is a small cooperative concurrency runtime for Lua, built on
**eventful transactions**.

A fibre does not block by directly receiving, sleeping, locking or updating
shared state.  It performs an operation value.  Operation values can be stored,
passed around, chosen between, sequenced, combined, and then committed by the
runtime.

The practical model is:

```text
spawn fibres
fibres perform operations
the runtime searches for a compatible committed world
resource changes and typed effects are committed
selected fibres resume with their results
```

The public base kit is deliberately small:

```text
Op       possible transaction
Cell     transactional fact
Channel  synchronous rendezvous
Source   external, host or time occurrence made transactional
Region   transactional ownership ledger
Lifetime compound transactional lifetime facility
Task     owned running computation
Effect   after-commit runtime obligation
```

The algebra underneath is the distinctive part.  A commit is not just one event
synchronising with another event.  A commit selects a world containing
rendezvous requirements, resource journals, fallback structure, wake interests,
typed runtime effects, nacks, and post-commit value transformations.

This repository is WIP.  The implementation is intended to be portable Lua;
this milestone has been exercised with `texlua`.

## Base kit rule of thumb

```text
Facts go in Cells.
Meetings go through Channels.
External occurrences arrive through Sources.
Ownership is recorded in Regions. Most lifetime-facing code uses Lifetime, a compound facility built over Region, Task, Source and Effect.
Running work is a Task.
Committed obligations are Effects.
Everything composes as an Op.
```

## A first example

```lua
local fibers = require('fibers')

local ch = fibers.Channel.new('inbox')
local message

fibers.launch(fibers.policy.nursery(), function()
  fibers.spawn(function()
    fibers.perform(ch:send_op('hello'))
  end, 'sender')

  message = fibers.perform(ch:recv_op())
end)

print(message)
```

`fibers.launch` installs an explicit lifetime policy.  Inside the nursery
policy, the friendly `fibers.spawn` creates a structured `Task`; raw unstructured
fibres remain available as `spawn_raw` for embedders and low-level tests.

The send and receive are not two independent actions.  The runtime finds one
compatible transaction and resumes both fibres after the rendezvous has
committed.

## Choice with time

A `Source` brings an external, host or time occurrence into the transaction
algebra.  `fibers.clock` is a clock source backed by the runtime's host clock.

```lua
local op = fibers.choice(
  ch:recv_op(),
  fibers.clock:after_op(1.0):map(function()
    return nil, 'timeout'
  end)
)
```

The same `Source` idea is used for manual events, host callbacks and readiness
sources.  Polling is one source kind, not the whole host model.

## Transactional state

Cells participate in the same transaction machinery as channels.

```lua
local counter = fibers.Cell.new(0, 'counter')

local increment = counter:update_op(function(old)
  return old + 1
end)
```

Cell predicates and update functions are speculative: they may run more than
once during search and must be pure.  Use `Effect` for committed external work.

## Lifetimes, regions and tasks

A region is a generic ownership and admission boundary.  A task is the standard owned computation: it is admitted to a region and started after the admitting transaction commits.

```lua
local life = fibers.Lifetime.new('main')

fibers.run(function()
  local task = fibers.perform(life:spawn_op(function()
    return 7
  end, { name = 'child' }))

  local status, value = fibers.perform(task:join_op())
  assert(status == 'ok' and value == 7)
  fibers.perform(life:release_op(task))
end)
```

`Region` is the ledger primitive: admit, transfer, seal and settle. `Lifetime` is the compound facility most code should use for spawning, cancellation, transfer, observation and release. Nursery and supervisor-style APIs are policies over `Lifetime`, not special cases in the algebra.

## Effects

An effect is the public form of a typed transaction consequence: runtime-owned
work that is published iff the selected world commits.

```lua
local op = fibers.after_commit(effect)
```

Effects are not participant continuations.  They are prepared and published by
the runtime after resource commit and before selected participants resume.

The current implementation provides in-process exactly-once publication.  It is
not yet a crash-durable distributed outbox.

## Public modules

```text
fibers                    convenience entry point
fibers.op                 operation constructors and combinators
fibers.runtime            fibre scheduler and transaction driver
fibers.cell               transactional Cell
fibers.channel            rendezvous Channel
fibers.source             Source abstraction
fibers.region             Region ownership ledger
fibers.lifetime           compound lifetime facility
fibers.task               Task owned computation handle
fibers.effect             typed Effect wrapper
fibers.resources.ledger   ownership ledger example resource
fibers.consequence.*      typed effect machinery for implementers
```

The direct modules are public.  The top-level module is the preferred starting
point:

```lua
local fibers = require('fibers')

local cell = fibers.Cell.new(false)
local ch = fibers.Channel.new()
local src = fibers.Source.manual('signal')
local life = fibers.Lifetime.new('main')
```

## Protected calls

Use `fibers.pcall` or `fibers.xpcall` inside fibres when protected code may perform operations. On Lua 5.1, native `pcall`/`xpcall` cannot reliably protect code that suspends and resumes, so `fibers` provides yieldable protected calls for fibre code without replacing the host globals.

This is deliberately proportionate: transaction search and commit internals remain non-suspending, and `perform` is only permitted from the currently resumed runtime fibre.

## Examples

The `examples/` directory contains small usage guides, not regression tests.
They are intended to be read and run individually:

```sh
lua examples/01_channel.lua
lua examples/02_cell.lua
lua examples/03_source.lua
lua examples/04_lifetime_task.lua
lua examples/05_effect.lua
lua examples/06_policy_nursery.lua
lua examples/07_lifetime_handoff.lua
```

Assertion-heavy semantic checks live in `tests/`.

## Run the tests

From the repository root:

```sh
lua tests/run_all.lua
# or
luajit tests/run_all.lua
# or
texlua tests/run_all.lua
```

Run the benchmark suite:

```sh
export FIBERS_BENCH_SCALE=20
lua benchmarks/bench.lua
# or
luajit benchmarks/bench.lua
# or
texlua benchmarks/bench.lua
```

## Documentation

```text
docs/base-kit.md       the public base kit
docs/algebra.md        operation algebra and semantic distinctions
docs/resources.md      open resource protocol
docs/consequences.md   typed transaction consequences / effects
docs/lifetimes.md      regions, tasks and ownership
docs/embedding.md      bounded stepping and host integration
```
