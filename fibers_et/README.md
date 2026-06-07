# lua-fibers

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
resource changes and typed consequences are committed
selected fibres resume with their results
```

The algebra underneath is the distinctive part.  A commit is not just one event
synchronising with another event.  A commit selects a world containing
rendezvous requirements, resource journals, fallback structure, wake interests,
typed runtime consequences, nacks, and post-commit value transformations.

This repository is WIP.  The implementation is intended to be portable Lua and
is currently tested with `lua`, `luajit` and `texlua`.

## Public modules

```text
fibers                    convenience entry point
fibers.op                 operation constructors and combinators
fibers.runtime            fibre scheduler and transaction driver
fibers.resources.cell     transactional value cell
fibers.resources.channel  rendezvous get/put channel
fibers.resources.ledger   ownership and settlement example
fibers.resources.event    manual waitable event resource
fibers.consequence.*      typed consequence machinery
```

The direct modules are public.  The top-level module is a convenience wrapper:

```lua
local fibers = require('fibers')

local Op = fibers.Op
local Runtime = fibers.Runtime
local Channel = fibers.Channel
local Cell = fibers.Cell
```

## Run the tests

From the repository root:

```sh
lua tests/run_all.lua
# or
luajit tests/run_all.lua
# even
texlua tests/run_all.lua
```

Run the benchmark suite:

```sh
export FIBERS_BENCH_SCALE=20
lua benchmarks/bench.lua
# or
luajit benchmarks/bench.lua
# even
texlua benchmarks/bench.lua
```

## A first example

A channel rendezvous commits only when both sides are present.

```lua
local fibers = require('fibers')

local Op = fibers.Op
local Runtime = fibers.Runtime
local Channel = fibers.Channel

local rt = Runtime.new()
local ch = Channel.new('inbox')

rt:spawn(function()
  local message = rt:perform(ch:get_op(Op))
  print('received', message)
end, 'receiver')

rt:spawn(function()
  rt:perform(ch:put_op(Op, 'hello'))
end, 'sender')

rt:run()
```

The get and put are not two independent actions.  The runtime finds one
compatible transaction and resumes both fibres after the rendezvous has
committed.

## A transactional state example

Cells participate in the same transaction machinery as channels.

```lua
local fibers = require('fibers')

local Op = fibers.Op
local Runtime = fibers.Runtime
local Cell = fibers.Cell

local rt = Runtime.new()
local counter = Cell.new(0, 'counter')

local function increment()
  return counter:get_op(Op):and_then(function(old)
    return counter:set_op(Op, old + 1):and_then(function()
      return Op.always(old, old + 1)
    end)
  end)
end

rt:spawn(function()
  local old, new = rt:perform(increment())
  print(old, new)
end)

rt:run()
```

The read and write are part of one operation.  If the chosen world cannot be
validated against committed state, the runtime rejects or retries the candidate
rather than publishing a half-transaction.

## Why operations instead of callbacks?

An operation is immutable transaction syntax:

```lua
local receive_number = ch:get_op(Op):map(function(x) return tonumber(x) end)
```

It can be stored, returned, combined, or performed later.  This is useful for
ordinary concurrency problems: choosing between input sources, updating state as
part of a rendezvous, admitting tasks, waking waiters, or publishing an outbox
obligation only if the surrounding transaction commits.

The important distinction is between code that constructs a possible world and
work that is caused by a committed world.

```text
wrap  = participant-level post-commit value transformation
emit  = transaction-level runtime consequence
```

A `wrap` runs inside the resumed fibre's `perform`.  An `emit` contributes a
typed obligation to the selected world.  If the world commits, the runtime
publishes the prepared consequence after resource journals are applied and before
selected fibres resume.  If the world loses, the consequence is discarded.

## The operation algebra, briefly

The core constructors are deliberately small:

```text
always(...)       current candidate returning values
never()           absence now
map               speculative value transformation
and_then          transactional sequencing
choice            eager competition between alternatives
or_else           residual fallback after absence-now
all               product without internal rendezvous closure
tensor            product with internal rendezvous closure
emit              typed transaction consequence
wrap              post-commit participant value transformation
```

Some distinctions are central:

```text
choice != or_else
all    != tensor
map    != wrap
emit   != wrap
wait   != candidate
journal != consequence
```

See `docs/algebra.md` for the public operation semantics.

## Resources

Channels are not special to the runtime.  They are one resource kind.  Cells,
ledgers, events and user resources participate through the same resource
protocol:

```text
evaluate operation
produce candidates and waits
merge resource records
prepare against committed state
apply prepared commits
optionally derive typed consequences
```

See `docs/resources.md` for the resource protocol and the trusted machinery
contract.

## Typed consequences

A consequence is a runtime-owned obligation carried by a candidate world.  Each
consequence kind defines:

```text
key       what counts as the same obligation
merge     how duplicate obligations combine or conflict
prepare   how the committed obligation is validated and made publishable
publish   how the runtime records or performs the obligation
```

This is useful for wakeups, outbox kicks, task admission, cache invalidation,
audit records, metering and resource finalisation.  It is not only for the
ledger example.

The current guarantee is in-process: a selected world publishes its prepared
consequences exactly once during that runtime commit.  This is not a claim of
crash-durable distributed exactly-once delivery.  For external systems, use a
consequence to install a durable obligation or idempotency key, then deliver it
outside the transaction.

See `docs/consequences.md` for the consequence model.

## Stepping and embedding

The runtime can be driven to completion:

```lua
rt:run()
```

or stepped with a bounded amount of algebra work:

```lua
local status = rt:step({ max_work = 100 })
```

This is intended for hosts that already own an event loop, such as games,
applications, document processors and LuaTeX-based tools.

## Error boundaries

The implementation uses three deliberately different boundaries:

```text
recoverable algebra callbacks
  guard, map, and_then and with_nack callback bodies
  raw callback failures become structured callback_error values

trusted transactional machinery
  solver, resource protocol, prepare/apply, commit and consequence machinery
  failures are runtime integrity failures

public driver boundary
  run and step restore driver state on exit
  structured fibers errors are re-raised as themselves
  raw machinery failures become fatal runtime_error values
```

After a fatal runtime error, the runtime object is no longer usable.

## Internal layout

```text
fibers.op
  -> fibers.algebra.*      operation evaluation, candidates, summaries, results
  -> fibers.solver.*       search, cursor and rendezvous closure
  -> fibers.commit.plan    inert commit plan construction
  -> fibers.runtime        scheduling and observable effect application
  -> fibers.resources.*    concrete resources and the resource protocol
  -> fibers.consequence.*  typed consequence kinds and sets
```

The rendezvous solver is deliberately not named after channels.  Channels are
the current public rendezvous primitive, but the solver works over generic
rendezvous endpoint records.
