# Performance and semantic invariants

Architectural performance work is accepted only when it preserves the operation
algebra and improves measured work rather than merely one elapsed-time sample.

## Semantic invariants

For every optimisation and every fixed input:

- the set of valid committed outcomes is unchanged;
- `Retry`, `Unknown` and certified negative proofs retain their meaning;
- speculative writes and effects remain isolated until commit;
- occurrence identity, product-lane compatibility and settlement truth are
  preserved;
- trail and reference evaluators agree on validating scenarios;
- a fixed machine, seed and frontier remains replayable;
- `Unknown` is never converted into a cached refutation;
- per-plan memoisation stores only refutations;
- cross-cycle positive reuse is restricted to effect-free, non-negative plans;
- opaque and external components remain outside reusable caches; and
- symmetry is applied only under an explicit complete-occurrence certificate.

Branch heuristics may select a different member of the existing valid outcome
set. Tests therefore compare exact results where the programme has one valid
answer and compare order-independent digests where several schedules are valid.

## Performance invariants

The suite records both ordinary throughput and solver shape:

- median microseconds per logical operation;
- p50, p95, p99 and maximum search steps;
- maximum per-plan search CPU time as a proxy for event-loop monopolisation;
- component size as a fraction of the complete pending frontier;
- branches, rollbacks, trail pressure and intent-pair scans;
- forced exchanges and claims;
- opaque versus analysable pending requests;
- repeated diagnostic search states;
- retained Lua heap after collection;
- no-supplier and state-memo hit rates;
- plan-cache hits, invalidations and ineligibility reasons; and
- certified symmetry reductions.

A change which improves the median while materially worsening p99 or maximum
search cost is not treated as a general improvement. Structural thresholds are
preferred to tight wall-clock thresholds in shared continuous-integration
runners.

## Workload classes

The principal suite retains simple, moderate and complex application-shaped
work. `performance/architecture_suite.lua` separately exercises the architectural
mechanisms and compares them with the legacy policy switches.
`performance/advanced_suite.lua` isolates the cache, memoisation, symmetry and
cross-cycle reuse passes from one another and retains ordinary rendezvous as a
fixed-cost control.
