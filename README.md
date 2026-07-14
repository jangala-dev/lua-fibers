# fibers

`fibers` is a cooperative concurrency runtime for Lua. Fibres perform inert operation values; a proof-search kernel finds a compatible committed world containing synchronous exchange, versioned state changes, ownership changes and post-commit obligations.

The production source uses the portable Lua 5.1 grammar. The version 1 runtime policy targets Lua 5.1, 5.2, 5.3, 5.4 and 5.5, the maintained LuaJIT `v2.1` branch, and Luau. Optional native host backends depend on modules available in the embedding environment; Luau host integration is treated separately from the stock-Lua module ABI.


## Repository layout

```text
src/          installable Fibers source
reference/    repository-only reference solver used for differential tests
tests/        correctness and host-backend tests
examples/     runnable examples
performance/  validating benchmarks and solver diagnostics
docs/         design and user documentation
```

Run repository commands from the project root so the development-only reference
path is available to tests and performance tools.

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

`guard(f)` performs activation-relative preparation. It is evaluated once for each speculative progression which enters it, so a guarded relative sleep begins when its enclosing `and_then` progression activates. Separate uses in a tensor or choice are independent; backtracking or resuming the same progression reuses the operation already returned by the guard.

## Declaring continuation dependencies

Arbitrary `guard` and `and_then` callbacks remain conservative: because the
operation returned by Lua code may depend on runtime values, an undeclared
continuation is treated as capable of touching the complete pending frontier.
Library and performance-sensitive code may declare a conservative union of the
operations the continuation can return:

```lua
local receive = inbox:get_op()
local op = prior:and_then(function(value)
  return receive
end, fibers.Op.dependencies(receive))
```

An incomplete declaration can make dependency isolation unsound.  During tests,
`Runtime.new({ verify_dependencies = true })` checks executed continuations and
rejects declarations which do not cover the returned operation.  Omitting a
declaration is always correct and uses the slower opaque path.

## Certified symmetry and adaptive search reuse

For homogeneous pending work, advanced code may certify that complete operation
occurrences are observationally interchangeable:

```lua
local send = queue:put_op(item):certify_symmetry('homogeneous-worker-send')
```

The certificate includes the fibre continuation after commit.  The runtime does
not infer symmetry, and an incorrect certificate can remove a valid committed
world.  Use a key only when any occurrence carrying that key may replace any
other without changing transactional behaviour.

The production trail machine also retains bounded `Unknown` searches by default,
resuming their explicit alternative stack while a conservative dependency stamp
remains valid.  This is controlled by `resumable_search`.

The runtime also enables three conservative search accelerators by default:

- a narrow no-supplier refutation cache;
- exact per-plan refutation memoisation; and
- dependency-stamped reuse of unchanged plans across driver cycles.

They are disabled automatically for opaque continuations and external
dependencies. `Unknown` is never cached, and positive cross-cycle reuse is
limited to effect-free candidates without negative guards.  The defaults are
adaptive: memo tables begin after 48 plan-wide search calls on structurally
large plans, and plan stamps are omitted until the total pending frontier
reaches sixteen.

They may be controlled explicitly when measuring or embedding:

```lua
local rt = fibers.Runtime.new({
  refutation_cache = true,
  state_memoization = true,
  certified_symmetry = true,
  plan_reuse = true,
  resumable_search = true,
  refutation_cache_min_steps = 48,
  state_memoization_min_steps = 48,
  plan_reuse_threshold = 16,
})
```

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
src/fibers/kernel/ir.lua            primitive programme records and footprints
src/fibers/kernel/store.lua         versioned locations, views, deltas and commit
src/fibers/kernel/choice_order.lua  deterministic unordered-choice permutation
src/fibers/kernel/dependencies.lua pending components, validation and coordination
src/fibers/kernel/frontier.lua      blocked-frontier analysis and branch ordering
src/fibers/kernel/adaptive_search.lua adaptive memoisation and retained proofs
src/fibers/kernel/machine.lua       trail-based proof and refutation search
src/fibers/kernel/search_session.lua retained search lifecycle
src/fibers/kernel/runtime.lua       fibres, recruitment, scheduling and host boundary
```

The copy-on-branch evaluator in `reference/fibers/internal/reference_machine.lua` consumes the same IR and store and is retained for differential testing:

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

The maintained aggregate suite currently contains 72 test programmes. Protected-call fallback and
lazy-reference loading also run in isolated interpreters. Useful runner options are:

```sh
lua tests/run_all.lua --list
lua tests/run_all.lua --filter external
lua tests/run_all.lua --verbose
lua tests/run_all.lua --fail-fast
```

Run examples and performance work with:

```sh
texlua examples/01_rendezvous.lua
lua performance/bench.lua
FIBERS_BENCH_CASE=product lua performance/bench.lua
texlua performance/suite.lua
FIBERS_PERF_TIERS=all texlua performance/suite.lua
texlua performance/seed_sweep.lua
texlua performance/architecture_suite.lua
texlua performance/advanced_suite.lua
```

`performance/README.md` describes the tiered validating suite, optional runtime
instrumentation, seed sweeps and CSV regression checks. Benchmarks are for local
regression work, not cross-machine claims.

## Formatting

Lua source is formatted with StyLua using the repository `.stylua.toml`. The
configured width is 100 columns, with two-space indentation and expanded simple
statements. Run:

```sh
scripts/check-format.sh
```

The ordinary `fibers` facade exposes application and embedding APIs. Trusted
facility authors may require `fibers.kernel` for `Runtime`, `IR` and `Store`;
the production machine, instrumentation implementation and prototype `Phase`
remain internal or explicitly imported modules.

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
performance/README.md        instrumentation and performance regression workflow
docs/notes/performance/      performance findings and optimisation history
```

The repository remains work in progress. Transactions are coherent within one runtime commit; they
are not crash-durable database or distributed transactions.
