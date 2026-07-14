# Advanced Lua performance passes for Fibers v1

## Scope

This pass implements the remaining architectural work identified after component
isolation, deterministic reductions and constrained branching:

8. narrow refutation caching;
9. exact per-plan state memoisation and explicitly certified symmetry; and
10. dependency-stamped plan reuse between runtime driver cycles.

The implementation remains in Lua and is intended to reduce redundant proof
work before any representation-level tuning.  The measurements in this note are
local TeXLua/Lua 5.3 regression figures.  They are not cross-machine claims.

## Safety rules

All three mechanisms are deliberately conservative.

- Caches are disabled for components containing opaque continuations or external
  dependencies.
- `Unknown` results are never cached.
- State memoisation stores refutations only, not successful candidates.
- Cross-cycle positive reuse is limited to non-negative, effect-free candidates.
- Cross-cycle entries are accepted only while the component dependency stamp is
  unchanged.
- Symmetry is never inferred from similar-looking options.  It requires an
  explicit certificate attached to the complete option occurrence.

The full aggregate suite runs against both the trail evaluator and the
copy-on-branch reference evaluator.  The reference evaluator now uses one shared
per-plan work counter, aligning its search budget and memoisation threshold with
the production evaluator rather than counting work independently in each clone.

## 8. Narrow refutation caching

The retained no-good is intentionally small:

> With this exact entered/excluded frontier, no remaining request footprint can
> supply any of these unresolved exchange roles or locations.

The key contains:

- the unresolved resource and role, or versioned location;
- entered request identities; and
- excluded request identities.

It omits values and continuation state because the corresponding supply query
uses only conservative dependency metadata.  The cache is private to one plan,
so the request set itself is fixed.

This replaces an earlier terminal-world cache.  The terminal cache could avoid
reconstructing a refutation but did not avoid search.  The no-supplier cache acts
earlier and can avoid repeated scans of the pending component.

The cache is allocated lazily after 48 search calls by default, and only for a
structurally large option or frontier.  On a deliberately global 65-request
frontier with 96 repeated blocked alternatives, the measured footprint checks
fell from 12,320 to 9,184 while search calls remained 322.  The median local
time fell from about 16.0 ms to 12.4 ms in the retained advanced suite run.

## 9. State memoisation

State memoisation is exact, per-plan and refutation-only.  A signature records:

- roots, exclusions and outcomes;
- task expressions, frames, active order and choice occurrences;
- products and lane outcomes;
- unresolved intents and scope paths;
- speculative views, observed versions and patches;
- effects, negative checks and fallback interests; and
- symmetry annotations.

Lua tables, functions and userdata retain identity semantics in the key.  The
cache therefore prefers a missed opportunity to an unsafe equality assumption.
It never persists beyond one call to the search machine.

Memo tables are created lazily after 48 plan-wide search calls by default, and
only when the option metadata or frontier indicates a structurally large
plan.  The threshold avoids hashing medium and simple searches where
reconstruction costs more than the work saved.  A runtime reuses one scratch
descriptor; the potentially large tables exist only for a plan which crosses
the threshold.

For 128 identical blocked choice alternatives, the adaptive configuration
reduced search calls from 258 to 98.  An eager diagnostic configuration reduces
them to four, but is not the default because eager hashing is costly on ordinary
workloads.

### Certified symmetry

Options may explicitly certify that pending occurrences sharing a key are
observationally interchangeable:

```lua
local op = channel:put_op(value):certify_symmetry('homogeneous-producer')
```

The certificate covers the complete occurrence, including the fibre continuation
which follows commit.  The runtime uses it in two places:

- compatible exchange partners with the same certified signature are represented
  once; and
- failed supplier recruitment can exclude the complete certified equivalence
  class after trying one representative.

A wrong certificate may remove a valid committed world.  It is therefore a
trusted, advanced API rather than an inferred optimisation.

In the adverse ten-producer benchmark, certified symmetry reduced:

- search calls from 4,134 to 82;
- branches from 8,164 to 96; and
- footprint checks from 22,526 to 402.

The local median fell from roughly 276 ms to 6.2 ms.  This is the strongest
result in the pass and is algorithmic rather than an inner-loop speed-up.

## 10. Cross-cycle plan reuse

Each analysable component can carry a dependency stamp containing:

- pending request and option identities;
- relevant versioned location versions;
- versioned resource-wide dependencies; and
- machine, seed, normalisation, branch and symmetry policies.

A stamp is unavailable for:

- opaque continuations;
- external dependencies;
- unversioned resource-wide dependencies; or
- a small runtime where neither the component nor the total frontier reaches the
  activation threshold.

The default activation threshold is sixteen.  A one-request blocked component
can therefore still be reused when it is one of many independent pending
components, while small and moderately contended frontiers avoid stamp
construction.

The cache retains:

- stable refutations; and
- effect-free positive candidates without negative guards.

A matching participant, relevant store write, resource version change or policy
change alters the stamp and invalidates the entry.  Cached entries are also
cleared when their focus leaves the pending frontier.

For 32 independent blocked requests across nine unchanged driver calls, search
calls fell from 320 to 63, with 257 plan-cache hits.  Local median time fell from
about 14.2 ms to 5.7 ms.

## Common-case cost

The facilities are enabled by default but adaptive:

- no supplier or state tables are allocated below their work and structural
  thresholds;
- plan stamps are omitted below a 16-request runtime frontier;
- opaque and external components do not enter the cache machinery; and
- ordinary binary rendezvous does not cross a cache threshold.

The advanced suite includes a same-tree `baseline` profile which disables all
three passes.  In the retained run, ordinary binary rendezvous was effectively
unchanged: 107.7 ms with the mechanisms disabled and 107.0 ms with the full
profile.  Very small TeXLua timings vary enough between process runs that this
report does not claim a precise universal fixed-cost percentage.  Structural
search counts remain unchanged below the activation thresholds.

## Validation

The added tests cover both evaluators and check:

- supplier no-good hits without altered search semantics;
- repeated-state memo hits and reduced search calls;
- symmetry remaining inactive without a certificate;
- certified supplier equivalence reducing repeated worlds;
- cross-cycle refutation and effect-free candidate reuse;
- invalidation after relevant location and pending-frontier changes; and
- exclusion of opaque continuations from all caches.

The advanced validating suite is:

```sh
texlua performance/advanced_suite.lua
FIBERS_ADV_MACHINE=reference texlua performance/advanced_suite.lua
FIBERS_ADV_FORMAT=csv FIBERS_ADV_OUTPUT=advanced.csv \
  texlua performance/advanced_suite.lua
```

## Remaining work

The principal architectural search passes are now present.  The next performance
work should be evidence-led profiling of the bounded implementation, including:

- cache memory and hit-rate measurements on long-running mixed applications;
- generated differential option graphs with varied seeds;
- LuaJIT and stock-Lua comparison on the same hardware;
- native-host throughput and latency suites; and
- only then dense representations, allocation reduction and hot-loop tuning.
