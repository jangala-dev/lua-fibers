# Performance architecture work for Fibers v1

## Scope

This pass implements the first seven architectural stages of the Lua performance
programme.  It deliberately addresses search shape before low-level allocation
or instruction tuning:

1. performance and semantic invariants;
2. diagnostic dependency and repeated-state measurement;
3. compiled operation metadata and continuation declarations;
4. incremental pending-request dependency indexes;
5. conservative dependency-component isolation;
6. deterministic normalisation and forced reductions; and
7. most-constrained residual branch ordering.

The measurements below were made on 12 July 2026 with TeXLua reporting Lua 5.3
and `os.gettimeofday` as the benchmark clock.  They are local regression figures,
not cross-machine performance claims.  LuaJIT and optional native host backends
were not available in this environment.

## Semantic safeguards

The work is guarded in four ways:

- the complete aggregate suite runs against both the production trail evaluator
  and the copy-on-branch reference evaluator;
- the architectural A/B suite compares validating result digests under the old
  and new policies;
- the seed sweep checks structural search cost across deterministic choice
  orders; and
- `performance/INVARIANTS.md` records the semantic and performance acceptance
  rules.

At the end of this pass, 66 aggregate test programmes pass under both evaluators,
including a full run with dependency verification forced on for every runtime.
The pure host test passes; eight optional native-host variants are skipped because
their dependencies are unavailable here.

## 1. Measurement and acceptance criteria

The validating performance suite now reports ordinary throughput separately from
instrumented diagnostic work.  It records:

- median time per logical operation;
- p50, p95, p99 and maximum search steps;
- per-plan CPU-time distributions;
- branches, rollbacks, trail entries and pair scans;
- component size relative to the complete pending frontier;
- forced exchanges and claims;
- analysable and opaque requests;
- repeated diagnostic search states; and
- potential reuse between successive plans.

`performance/architecture_suite.lua` runs the old and new architectural policies
side by side.  `performance/seed_sweep.lua` checks choice-order sensitivity rather
than accepting a favourable default seed.

## 2. Diagnostic dependency model

Operation metadata is compiled and cached by operation identity.  It records:

- exchange resources and roles;
- versioned locations and access modes;
- resource-wide dependencies;
- operation-node kinds and counts;
- external dependencies; and
- whether any continuation remains opaque.

The runtime instrumentation measures component reduction, dependency counts,
opaque slow paths and repeated coarse search states without making those hashes
part of normal execution.

## 3. Continuation metadata

`map` is recognised as a closed continuation.  `guard` and `and_then` accept an
optional conservative continuation declaration:

```lua
local next_op = channel:get_op()
local op = prior:and_then(function(value)
  return next_op
end, Op.dependencies(next_op))
```

Declarations may combine several operations or metadata parts.  They state the
union of dependencies the callback may return, not the operation it must return
on every invocation.

An unannotated arbitrary Lua continuation remains dynamic and conservatively
connected to the whole pending frontier.  Correctness therefore does not depend
on users supplying metadata.

For library development, `Runtime.new({ verify_dependencies = true })` checks an
executed continuation against its declaration and rejects an incomplete one.
This is intended as a test and development aid; verification is not enabled on
the normal fast path.

Task, Scope, Region, Flow and benchmark-owned continuations whose future
operations are structurally known now use this declaration path.

## 4. Incremental pending dependency index

For sufficiently large pending frontiers, the runtime maintains an index from:

- exchange resources and complementary roles to pending roots;
- versioned locations to pending roots and possible suppliers;
- resource-wide dependencies to pending roots; and
- opaque continuations to the conservative global set.

The index is activated adaptively at 16 pending requests and normally released
only after the frontier falls below 8.  This hysteresis avoids rebuilding the
index when a workload oscillates around the activation boundary.  Small
frontiers use direct scans and avoid the fixed cost of maintaining a graph for
one- and two-party operations.

A per-search-node exchange-intent index was also tested.  It reduced comparisons
but allocated enough Lua tables to slow ordinary rendezvous after component
reduction.  It was removed.  This is a useful boundary: the retained index is
runtime-wide and incremental; the small residual intent set is scanned directly.

## 5. Dependency-component isolation

A plan now receives only the connected pending component containing its focus,
provided the component is statically analysable.  Roots are connected through:

- complementary exchange roles on the same resource;
- shared versioned locations;
- resource-wide observation or supply; and
- opaque continuation dependencies.

Opaque requests deliberately join the complete frontier.  The optimisation is
therefore conservative: missing metadata loses performance but does not silently
remove a possible participant.

In the architectural suite, 24 unrelated blocked rendezvous roots search a
component averaging about 17.5% of the former complete frontier.  Footprint checks
fall from 828 to 105 in that scenario.

## 6. Deterministic normalisation

Before ordinary branching, both evaluators recognise certified forced work:

- a sole compatible binary rendezvous with no unentered possible supplier;
- a sole all-member, non-supplying claim group with no unentered possible
  supplier; and
- deterministic operation prefixes already handled by the evaluator loop.

These reductions do not guess a preferred outcome.  They remove a branch only
when no alternative remains in the current conservative component.

In the architectural suite:

- an 80-step binary rendezvous sequence falls from 322 to 161 branches; and
- an 80-step scalar-query sequence falls from 80 claim branches to zero.

## 7. Most-constrained branch policy

When genuine ambiguity remains, the solver selects the exchange intent with the
smallest positive compatible-partner domain.  Ties retain stable identity order,
and the deterministic choice seed orders otherwise equivalent alternatives.
Claim groups are similarly ordered by their viable domain.  Recruitment prefers
the pending root capable of satisfying the greatest number of current blocked
requirements.

This is shared by the trail and reference evaluators so the reference path
continues to exercise the same semantics, while retaining its deliberately
simpler copy-on-branch store implementation.

## Principal structural result

The previous structured-rendezvous seed cliff has been removed for the measured
family.

Before this pass:

- fanout five ranged from 28 to 7,915 maximum steps across seeds;
- fanout eight ranged from 28 to 251,179 maximum steps;
- the slow fanout-eight runs took about 5.5 seconds locally.

After this pass:

- fanouts 4 through 8, seeds 1 through 16, all have a maximum plan of 8 steps;
- fanouts 8 through 16, seeds 1 through 4, also all have a maximum plan of 8
  steps; and
- the slowest measured fanout-eight seed in the 16-seed sweep took about 19 ms.

This is an algorithmic result rather than an inner-loop speed-up.  The runtime is
no longer traversing hundreds of thousands of equivalent or poorly ordered
worlds for this pattern.

## Current local baseline

The current tiered run gives the following representative results:

| Workload | Median | p99 upper bound | Maximum steps |
|---|---:|---:|---:|
| always perform | 17.2 us/op | 1 | 1 |
| scalar read/write | 28.5 us/op | 1 | 1 |
| two-fibre rendezvous | 95.8 us/op | 4 | 3 |
| internal then external rendezvous | 183.4 us/op | 4 | 4 |
| task spawn, await and settlement | 1.50 ms/op | 8 | 5 |
| triple swap with decoy | 2.24 ms/op | 64 | 37 |
| contended producers | 97.3 us/op | 4 | 3 |
| nursery rendezvous fanout seven | 1.13 ms/op | 8 | 8 |

Compared with the preceding instrumented baseline, the strongest changes are:

- triple swap: 79 to 37 maximum steps and roughly 3.18 to 2.24 ms/op;
- nursery fanout seven: 28 to 8 maximum steps and roughly 1.92 to 1.13 ms/op;
- choice-conflict backtracking: roughly 71.9 to 64.8 us/op; and
- scalar read/write: roughly 29.5 to 28.5 us/op.

Some common cases are slower relative to the earlier archived run, notably
two-party rendezvous, the interacting product, Flow and contended producers.
Those measurements were taken at different points in the session and should not
be read as a clean A/B result.  In the same-process architectural A/B suite, the
new trail policy is about 4% faster for the binary sequence, essentially even
for contended producers, and about 38% faster for the triple swap.  The residual
common-case cost nevertheless remains a legitimate target for later profiling;
it should not be obscured by the large tail improvement.

## What has not been implemented

This pass stops deliberately after stage seven.  It does not yet add:

- no-good or refutation caches;
- whole-state memoisation;
- certified participant symmetry;
- cross-cycle plan or deterministic-prefix reuse; or
- dense-array, arena, pooling or other Lua micro-optimisations.

The instrumentation added here is intended to make those later decisions
evidence-led.

## Recommended next order

The next principled work is:

1. use the repeated-state diagnostics to define narrow, dependency-versioned
   no-good caches;
2. add generated differential operation graphs and larger mixed-component
   workloads;
3. measure cache hit rate and invalidation before retaining any cache;
4. introduce cross-cycle component refutation reuse;
5. consider certified symmetry only for built-ins able to provide an exact
   equivalence key; and
6. profile the now-bounded hot paths before changing Lua representation.

The main performance objective remains: ordinary programmes should reach the
search machine with a small relevant component, exhaust deterministic work, and
branch only over genuine residual ambiguity.
