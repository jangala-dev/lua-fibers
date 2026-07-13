# Fibers performance suite

This directory contains a validating performance suite for the prospective v1
runtime. It is intended for local optimisation and continuous-integration
regression checks of the Lua implementation.

The suite separates two activities:

1. headline timings, collected with instrumentation disabled; and
2. one diagnostic run, collected separately with proof-search instrumentation.

This separation is important. Instrumentation is useful for explaining a result,
but its table updates, clock reads and retained slow-plan records should not be
included in the throughput figure being explained.

## Quick use

From the repository root:

```sh
texlua performance/suite.lua
FIBERS_PERF_TIERS=all texlua performance/suite.lua
FIBERS_PERF_FORMAT=csv FIBERS_PERF_OUTPUT=results.csv texlua performance/suite.lua
FIBERS_PERF_FORMAT=json FIBERS_PERF_OUTPUT=results.json texlua performance/suite.lua
```

The suite also runs with `lua` and `luajit`, subject to the normal library and
host requirements.

The default run includes the simple and moderate tiers. The complex tier is
explicit because it contains deliberate proof-search stress cases.

## Workload tiers

### Simple

- `always perform`: kernel, coroutine and commit floor;
- `serial read write`: versioned scalar read/write transactions;
- `two fibre ping pong`: ordinary two-party rendezvous;
- `preloaded event queue`: external delivery and consumption.

### Moderate

- `internal then external rendezvous`: interacting product followed by an
  external partner;
- `choice conflict backtracking`: a small conflicting product with fallback;
- `sequential write read`: Flow state transitions and buffering;
- `spawn await settlement`: structured task creation, completion and settlement.

### Complex

- `triple swap with decoy`: global coordination with an unproductive partner;
- `contended producers`: many pending senders sharing one rendezvous;
- `nursery rendezvous fanout seven`: structured ownership and rendezvous under a
  deliberately awkward frontier.

Every case validates its result. A fast but incorrect run fails the suite.

## Controls

```text
FIBERS_PERF_SCALE             multiplier for each case's iteration count
FIBERS_PERF_REPEATS           timed samples; median is reported
FIBERS_PERF_WARMUP            0 disables warm-up runs
FIBERS_PERF_TIERS             simple, moderate, complex, or all
FIBERS_PERF_CASE              literal substring filter
FIBERS_PERF_FORMAT            text, csv, or json
FIBERS_PERF_OUTPUT            optional output file
FIBERS_PERF_MACHINE           trail or reference
FIBERS_PERF_SEED              deterministic choice seed
FIBERS_PERF_DIAGNOSTICS       0 disables the separate diagnostic pass
FIBERS_PERF_TRACE             1 retains capped events for the slowest plans
FIBERS_PERF_STATE_HASH        0 disables diagnostic duplicate-state hashing
FIBERS_PERF_SLOW_PLANS        number of slow-plan summaries to retain
FIBERS_PERF_ADVANCED          full or off; A/B the passes 8--10 defaults
```

Use the same interpreter, host, CPU policy and environment when comparing two
runs. The figures are local regression measurements, not cross-machine claims.

## Runtime instrumentation

Instrumentation is opt-in:

```lua
local Runtime = require('fibers.kernel.runtime')

local rt = Runtime.new({
  instrumentation = {
    slow_plan_limit = 16,
    trace = false,
  },
})

-- Run work, then inspect a detached snapshot.
local snapshot = rt:instrumentation_snapshot()
rt:reset_instrumentation()
```

An ordinary runtime has `instrumentation == nil` and pays only guarded checks at
instrumentation sites. Timings in `suite.lua` use this ordinary path.

The snapshot contains:

- cumulative counters;
- high-water marks;
- power-of-two histograms;
- summaries of the slowest plans;
- optional capped plan events.

Important counters include search calls, branches, rollbacks, trail entries,
intent-pair scans, compatible exchange pairs, claim branches, recruitment and
exclusion branches, footprint matches, machine-transition work, commits,
validation failures and fibre activity.

Important distributions include search steps per plan, search CPU time per plan,
participants per candidate, roots, intents and trail entries. The suite derives
p50, p95 and p99 upper bounds from these histograms and reports the exact maximum
separately.


## Architectural A/B suite

The first seven architectural stages are exercised separately:

```sh
texlua performance/architecture_suite.lua
FIBERS_ARCH_FORMAT=csv FIBERS_ARCH_OUTPUT=architecture.csv \
  texlua performance/architecture_suite.lua
```

The suite runs both the legacy policy switches and the new architecture, by
default against both trail and reference evaluators. It checks one validating
digest per case and reports component fraction, forced reductions, opaque
requests, duplicate diagnostic states and search work. Set `FIBERS_ARCH_FANOUT8=1` to include fanout eight explicitly.  It is no
longer pathological under the current policy, but remains opt-in so the A/B
suite stays compact.

The acceptance rules are recorded in `performance/INVARIANTS.md`.


## Advanced cache and symmetry suite

The remaining architectural passes have a separate validating comparison:

```sh
texlua performance/advanced_suite.lua
FIBERS_ADV_MACHINE=reference texlua performance/advanced_suite.lua
FIBERS_ADV_FORMAT=csv FIBERS_ADV_OUTPUT=advanced.csv \
  texlua performance/advanced_suite.lua
```

It runs four profiles over the same validating scenarios:

- `baseline`: all remaining mechanisms disabled;
- `refutation`: narrow supplier no-goods only;
- `memo`: refutation caching plus adaptive per-plan state memoisation; and
- `full`: refutation caching, state memoisation, certified symmetry and
  cross-cycle plan reuse.

The cases cover repeated blocked alternatives, repeated supplier refutations,
certified homogeneous suppliers, unchanged blocked driver cycles, ordinary
binary rendezvous and the triple-swap stress case.  CSV output includes search
calls, branches, footprint checks, cache hits, symmetry pruning and plan reuse.

Controls are:

```text
FIBERS_ADV_REPEATS        timed samples; median is reported
FIBERS_ADV_FORMAT         text or csv
FIBERS_ADV_OUTPUT         optional output file
FIBERS_ADV_MACHINE        trail or reference
FIBERS_ADV_CASE           literal substring filter
```

The safety model and current measurements are recorded in
`docs/notes/performance/PERFORMANCE-PASSES-8-10.md`.

## Sparse store-view suite

Product lanes use sparse parent-linked speculative views.  The focused store
benchmark first observes a configurable number of locations in a parent view,
then forks a configurable product.  It reports both elapsed time and
GC-disabled transient allocation per round:

```sh
texlua performance/store_view_suite.lua
FIBERS_STORE_CELLS=32 FIBERS_STORE_LANES=16 FIBERS_STORE_ROUNDS=500 \
  texlua performance/store_view_suite.lua
```

The benchmark validates its result.  It is intended to detect regressions in
view forking, copy-on-write promotion and product merging rather than general
proof-search changes.

## Seed sweep

Choice ordering can expose or hide combinatorial search. Sweep the known
structured rendezvous shape rather than relying on one favourable seed:

```sh
texlua performance/seed_sweep.lua
FIBERS_SWEEP_MIN_SIZE=4 FIBERS_SWEEP_MAX_SIZE=8 \
FIBERS_SWEEP_MIN_SEED=1 FIBERS_SWEEP_MAX_SEED=16 \
FIBERS_SWEEP_OUTPUT=seed-sweep.csv \
texlua performance/seed_sweep.lua
```

The default sweep remains deliberately small for routine regression work.  The
current architecture keeps the measured fanout 4--16 family to a maximum of
eight search steps, but larger and mixed workloads should remain separate CI
jobs so a future change cannot reintroduce a seed-dependent cliff unnoticed.

## Regression comparison

Create two CSV runs with identical settings, then compare them:

```sh
FIBERS_PERF_FORMAT=csv FIBERS_PERF_OUTPUT=baseline.csv texlua performance/suite.lua
# change the implementation
FIBERS_PERF_FORMAT=csv FIBERS_PERF_OUTPUT=candidate.csv texlua performance/suite.lua
texlua performance/compare.lua baseline.csv candidate.csv 10 25
```

The final two arguments are the permitted percentage regressions for median
microseconds per operation and p99 search-step upper bound. The command exits
non-zero when either threshold is exceeded.

For continuous integration, use several repetitions, pin the machine and choice
seed, and run the seed sweep as a separate job. Performance CI on shared hosts
should use generous timing thresholds while keeping strict structural thresholds
for search steps and branch counts.

## Validating benchmark harness

`bench.lua` is the broad, validating local-regression harness. Run it from the
repository root:

```sh
lua performance/bench.lua
luajit performance/bench.lua
texlua performance/bench.lua
```

Controls include `FIBERS_BENCH_SCALE`, `FIBERS_BENCH_REPEATS`,
`FIBERS_BENCH_CASE` and `FIBERS_BENCH_FORMAT`.

The focused compatibility diagnostics are retained under
`performance/diagnostics/`:

```text
flow.lua            Flow sequential and tensor throughput
petri_calendar.lua  constant-state and growing-state behaviour
region.lua          persistent ownership-ledger growth
search_cases.lua    search calls, rollbacks, trail entries and refresh statistics
```

These scripts are not part of the validating benchmark harness. The reference
evaluator may be selected with `FIBERS_MACHINE=reference` for differential
measurements.

## Interpretation

A timing regression with unchanged search steps usually points to allocation,
store, coroutine or host overhead. A step-count regression is generally more
serious: it indicates a changed search shape and is likely to become much larger
at a slightly greater frontier.

Do not optimise only the mean. For this runtime the primary solver health
measures are p95, p99 and maximum search steps, branches, rollback entries and
retained trail pressure across several choice seeds.
