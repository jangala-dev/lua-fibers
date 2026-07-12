# fibers

`fibers` is a cooperative concurrency runtime for Lua. Fibres perform inert operation values; a proof-search kernel finds a compatible committed world containing synchronous exchange, versioned state changes, ownership changes and post-commit obligations.

The production source uses the portable Lua 5.1 grammar and is intended for stock Lua, LuaJIT and TeXLua. The current repository CI exercises the portable TeXLua path; a wider interpreter matrix is deferred until the release process is established. Optional native host backends depend on modules available in the embedding environment.

## The operation algebra

The canonical operation forms are:

```text
always(values)
primitive(programme)
choice(operations)
and_then(operation, values -> operation)
product(independent | interacting, lanes)
or_else(primary, fallback)
consequence(effect)
```

The public helpers `never`, `map`, `guard`, `all`, `tensor` and `emit` elaborate to those forms. `wrap` and `on_defeat` annotate dynamic occurrences.

The central distinctions are:

```text
choice      unordered alternatives with no source-position priority
or_else     fallback only after a complete, valid Retry proof
all         lanes commit together but cannot positively supply one another
tensor      lanes commit together and may perform intentional hand-off
Retry       the preferred search scope is presently impossible
Unknown     bounded search has not established Hit or Retry
wrap        participant-local work after commit
consequence runtime-owned work selected with the committed world
```

## First programme

```lua
local fibers = require('fibers')

local inbox = fibers.Rendezvous.new('inbox')

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(inbox:put_op('hello'))
  end, 'sender')

  assert(fibers.perform(inbox:get_op()) == 'hello')
end)
```

`fibers.run` creates a runtime and root scope. `fibers.spawn` creates a structured task owned by the current scope. `fibers.perform` submits an operation to the runtime.

The put and get commit as one rendezvous. Neither side proceeds alone.

## Unordered choice and principled priority

`choice` expresses indifference between acceptable committed worlds:

```lua
local value = fibers.perform(fibers.choice(
  left:get_op(),
  right:get_op()
))
```

When several branches can commit, source position gives no branch priority. Unbiased here means absence of source-position priority, not statistical uniformity. The runtime explores a deterministic permutation derived from `Runtime.new({ choice_seed = ... })`. Reusing the seed with the same programme, request sequence and external inputs reproduces the traversal. No fairness or uniform-probability guarantee is made.

`or_else` expresses validated instantaneous priority:

```lua
local value = fibers.perform(
  cache:get_op(key):or_else(fibers.always(default_value))
)
```

The fallback is searched only after the primary has been exhaustively refuted under recorded versioned facts. A search budget expiring produces `Unknown`, not `Retry`, and cannot enable the fallback. A fallback candidate is validated again before commit.

The two operators form useful priority tiers:

```lua
local result = fibers.perform(
  preferred:or_else(fibers.choice(
    acceptable_a,
    acceptable_b,
    acceptable_c
  ))
)
```

This means: prefer `preferred` whenever it can commit in the selected world; otherwise choose without source-order preference among the acceptable alternatives. Conversely, `fibers.choice(a, b):or_else(fallback)` admits the fallback only when both `a` and `b` have been refuted.

## Products

`all` is independent joint satisfaction:

```lua
local a, b = fibers.perform(fibers.all({
  left:take_op(1),
  right:take_op(1),
}))
```

`tensor` additionally permits intentional sibling hand-off:

```lua
fibers.perform(fibers.tensor({
  slots:give_op(1),
  slots:take_op(1),
}))
```

In both modes, sibling changes must form one coherent final world. Under `all`, a sibling may constrain or invalidate another lane but may not make an otherwise-unready lane ready. Under `tensor`, compatible positive supply is allowed.

## Transactional facilities

The fixed compact kernel supports versioned locations, deterministic and witnessed partial transducers, version waits and linear exchange. Public facilities compile to that substrate; they do not extend search, Retry, validation or commit semantics.

The low-level atom kit includes:

```text
Scalar       replacement facts and serial state machines
Rendezvous   synchronous one-use exchange
Counter      bounded numeric stock
Keyed        keyed presence and absence
Index        ordered allocation
Lease        compatibility-managed rights
Signal       externally latched fact
EventQueue   externally delivered transactional events
Clock        host-time observation
Readiness    host readiness levels
Region       ownership and custody ledger
Effect       typed post-commit obligations
```

Additional public facilities include:

```text
Queue, Channel, PriorityQueue, Pool, Mailbox, Pulse, WaitGroup
RateLimiter, Task, Scope, Flow, Stream
Petri, Calendar
```

`Petri` provides coloured linear-multiset transitions. `Calendar` provides witnessed multi-resource interval reservation. Both use the same global alternative search as ordinary `choice` and rendezvous matching.

## Structured lifetimes

```lua
fibers.scope(function(scope)
  local task = scope:spawn(function()
    return 7
  end)

  assert(fibers.perform(task:await_op()) == 7)
end)
```

Scopes record custody in a Region ledger. On exit, policy seals admission, accounts for retained roots and runs settlement protocols. A failed settlement remains represented as unresolved ownership truth rather than being silently discarded.

## Flows and streams

A `Flow` is a transactional byte reservoir. A `Stream` is a bidirectional pair of flows.

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
assert(fibers.perform(b:reader():read_line_op()) == 'hello')
```

Losing writes append nothing and losing reads consume nothing. Host-backed streams use readiness and pump tasks; irreversible I/O occurs only after a readiness operation commits.

## External observations and embedding

The runtime can be driven directly:

```lua
local rt = fibers.Runtime.new({
  host = fibers.host.manual(),
  choice_seed = 17,
})
local signal, feed = rt:signal('shutdown')

rt:spawn_raw(function()
  assert(rt:perform(signal:wait_op()) == 'requested')
end, 'waiter')

feed:set('requested')
rt:run()
```

Signal, EventQueue and Readiness producers receive runtime-bound feed capabilities. Clock waits are validated against host time. An uncaught Retry may report timer or external interests to an embedding loop.

## Kernel architecture

The active semantic kernel is deliberately small:

```text
fibers/kernel/ir.lua            primitive programme records and footprints
fibers/kernel/store.lua         versioned locations, views, deltas and commit
fibers/kernel/choice_order.lua  deterministic unordered-choice permutation
fibers/kernel/machine.lua       trail-based proof and refutation search
fibers/kernel/runtime.lua       fibres, recruitment, scheduling and host boundary
```

The copy-on-branch evaluator in `fibers/internal/reference_machine.lua` consumes the same IR and store and is retained for differential testing:

```sh
FIBERS_MACHINE=reference lua tests/run_all.lua
texlua tests/run_protected_fallback.lua
texlua tests/test_reference_lazy.lua
```

## Running the repository

```sh
texlua tests/run_all.lua
FIBERS_MACHINE=reference texlua tests/run_all.lua
texlua tests/run_protected_fallback.lua
texlua tests/test_reference_lazy.lua
```

The maintained aggregate suite currently contains 64 test programmes. Protected-call fallback and lazy-reference loading also run in isolated interpreters. Useful runner options are:

```sh
lua tests/run_all.lua --list
lua tests/run_all.lua --filter external
lua tests/run_all.lua --verbose
lua tests/run_all.lua --fail-fast
```

Run examples and benchmarks with:

```sh
texlua examples/01_rendezvous.lua
lua benchmarks/bench.lua
FIBERS_BENCH_CASE=product lua benchmarks/bench.lua
```

Benchmarks are for local regression work, not cross-machine claims.

## Documentation

```text
docs/guide.md               application-facing programming guide
docs/algebra.md             semantic model, laws and non-laws
docs/lifetimes.md           custody, authority and settlement
docs/embedding.md           runtime driving, hosts and external feeds
docs/resource-authoring.md  trusted compact-facility authoring
docs/internals.md           compact kernel and execution pipeline
docs/comparison.md          comparison with CSP, CML, Transactional Events and Reagents
docs/compatibility.md       portable coding constraints and current test environment
```

The repository remains work in progress. Transactions are coherent within one runtime commit; they are not crash-durable database or distributed transactions.
