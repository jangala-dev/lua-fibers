# Proof-engine efficiency programme

The production evaluator remains one lazy proof machine. Performance work must
improve the precision and economy of that machine; it must not divert selected
option shapes to a second transactional system or a manually maintained fast
path.

The repository's copy-on-branch reference evaluator remains an independent test
oracle. It is not an application execution tier.

## Working hypothesis

External-resource drivers are useful forcing cases because they submit many
small but semantically ordinary options. They expose when the lazy machine:

- builds a dependency component which is broader than the actual decision;
- introduces a branch for a reduction which has only one semantic outcome;
- journals the same mutable search field repeatedly within one checkpoint;
- reconstructs a stable proof shape unnecessarily;
- repeats a negative proof after none of its dependencies changed.

The target is not an I/O exception. It is a machine which derives less work from
more precise knowledge of the same option graph.

## Measurement

Run:

```sh
make profile-proof-io
FIBERS_PROOF_SLOW=1 make profile-proof-io
FIBERS_PROOF_FORMAT=csv lua performance/proof_engine_io.lua
```

The profile reports both elapsed time and solver shape:

- plans and commits;
- search calls, branches and rollbacks;
- claim branches and forced claim reductions;
- trail entries and coalesced writes;
- static option-node counts;
- location, resource and exchange dependencies;
- maximum dependency-component size;
- search, branch and trail work per commit.

Timing is secondary. A kernel change is accepted first on structural evidence,
then checked for ordinary elapsed-time and allocation regressions.

## Pass 1: shape and dependency observability

Instrumentation records the static shape of every searched component. These
counters are collected only when instrumentation is enabled:

```text
option_nodes
option_kind_*
option_dynamic_roots
option_external_roots
dependency_locations
dependency_resources
dependency_exchanges
```

This permits a slow plan to be described as both a search process and an option
component.

## Pass 2: unavoidable non-supplying claims

A location containing only machine transitions which do not accept supply has one semantic
journal: all currently entered transitions in their declared serial order.
Once the dependency frontier proves that no pending root can add a constraining
participant at that location, creating a branch frame cannot reveal another
world. The production machine now performs that reduction in place and lets the
nearest genuine outer alternative provide rollback if later work fails.

This remains the same lazy fixed-point search. It improves its normalisation
step; it does not dispatch the transaction elsewhere.

In a local ManualHost comparison:

| Workload | Metric | Before | After |
|---|---:|---:|---:|
| 2 socket lifecycles | search calls | 6,082 | 1,197 |
| 2 socket lifecycles | branches | 16,332 | 850 |
| 2 socket lifecycles | trail entries | 85,772 | 6,604 |
| 16 datagrams | search calls | 4,425 | 3,894 |
| 16 datagrams | branches | 7,805 | 5,511 |
| 16 datagrams | trail entries | 79,600 | 42,582 |

The eight-connection socket baseline fell from roughly 3.0 seconds to 0.35
seconds in the same local environment. The 64-datagram baseline improved from
roughly 1.01 seconds to 0.79 seconds. These are local regression measurements,
not portable performance claims.

## Pass 3: checkpoint journal precision

Within one speculative checkpoint, rollback needs the value which preceded the
first write to a field, not an entry for every subsequent write. The trail now
coalesces:

- repeated writes to the same table field within one mark; and
- repeated pushes to the same array within one mark.

Nested marks retain independent first-write records and restore the parent's
stamp when rolled back. This reduces trail volume without changing the search
state representation or rollback model.


## Pass 4: exact continuation footprints

The remaining slow datagram plans initially contained three dynamic roots in a
four-root component.  The roots were not inherently dynamic: common internal
`and_then` continuations had omitted an upper-bound footprint, so the dependency
model had to assume that they could later touch any managed resource.

The queue, lifecycle, datagram send-state and service-policy continuations now
declare exact closed footprints.  Dependency verification is enabled in the
proof profile and in the core datagram test, so an understated declaration is a
test failure rather than a silent optimisation hint.

This is a general precision improvement.  The option remains an ordinary
continuation in the same lazy machine; the machine merely knows its actual
possible locations before recruiting unrelated pending roots.

## Pass 5: directional supply metadata

A write to a location is not necessarily capable of satisfying every claim on
that location.  For example, decrementing a Counter cannot positively supply
another upward Counter claim, and removing an Index entry cannot supply a
selection which needs an entry to exist.

Dependency metadata and supplier indexes now use one canonical set:

```text
supplies = { up = true }
supplies = { down = true }
supplies = { any = true }
```

Recruitment compares that set with the claim's orientation before treating a
pending request as a possible supplier.  `any` is explicit; omission means no
supply.

This prevents false include/exclude worlds from entering the same search while
preserving all genuinely supplying and constraining relationships.

## Pass 7: canonical supply protocol

All trusted resources, state-machine transitions, witnessed transitions,
continuation footprints and case studies now use the canonical `supplies` set.
The former umbrella flag and flat directional fields were removed from option
metadata, dependency verification and supplier indexes.

Machine and witnessed transitions also declare `accepts_supply` separately.
This distinguishes two questions which the earlier field conflated: whether a
transition may be made ready by same-world state, and whether its own state
change may make another intent ready.  Missing or legacy declarations are
construction errors.

The consolidation preserves the pass-six proof shape.  In the standard I/O
profile, datagrams remain at approximately 5.5 search rounds and 3.8 branches
per commit; socket, stream and reactor profiles are likewise unchanged within
measurement noise.  The purpose of this pass is structural: future resources
cannot silently widen recruitment by omitting directional metadata.

## Pass 6: same-location claim closure

A group of claims on one location often has a direct serial closure.  The lazy
machine now offers that complete closure as the first frontier alternative.  It
repeatedly chooses a claim which is ready in the provisional world constructed
so far, allowing one sibling's transition to make another sibling ready.

The existing singleton alternatives remain in the frontier.  If the closure's
ready-first order fails, the same machine backtracks and explores other serial
orders.  Regression tests cover both:

- an Index insertion supplying a same-world pop; and
- a closure which fails after taking stock, then succeeds by observing the
  stock before taking it.

This is not a forced reduction and does not introduce a second evaluator.  It
is a better first branch in the existing lazy enumeration.

A more aggressive experiment which forced an apparently isolated singleton
claim was rejected.  It changed a messaging/countdown result because a later
continuation could still make another serial world relevant.  This confirmed
that generic singleton claims are genuine lazy choices unless the existing
frontier proof establishes otherwise.

## Pass 6 measurements

With 16 ManualHost datagram round trips, the structural profile changed from
pass one's residual workload as follows:

| Metric per commit | Pass 1 | Pass 6 |
|---|---:|---:|
| search calls | 25.5 | 5.5 |
| branches | 36.0 | 3.8 |
| trail entries | 278.3 | 42.9 |

The total claim branches fell from 2,901 in the original residual trace to 216.
The current run offered three same-location closures and all three succeeded.
Maximum dependency-component size remained four, showing that the improvement
came from precision inside the component rather than excluding a required
participant.

A local 64-datagram baseline fell from roughly 0.83 seconds after pass one to
roughly 0.18 seconds after these changes.  These timings are regression
measurements for one environment, not portable throughput claims.

## Retained-search findings

The profile now records why retained sessions become invalid.  In the current
16-datagram workload, 18 retained proofs were invalidated:

```text
16  exact location-version changes
 2  dependency-bucket generation changes
 0  request replacement
 0  broad external generation
 0  runtime epoch or timer expiry
```

This is encouraging: retained proofs are no longer being lost through opaque
request membership or a global external-generation dependency.  Most remaining
invalidations correspond to the private queue, lifecycle or completion state
which the next packet genuinely changes.

The next retained-search question is therefore whether a location change can
reopen only the affected residual frontier, not whether the dependency vector
is still too broad.

## Next investigations

### Residual reopening after location change

Most datagram invalidations are now exact location-version changes.  Record
which residual branches depend on each location and reopen only the affected
subtree when that location changes, retaining unaffected refutations in the
same search session.

### Claim-closure ordering and allocation

Measure the number of provisional projections and temporary arrays used by a
closure.  The semantic alternatives are now appropriate; the closure cursor
can still be made lazier and less allocation-heavy without changing its worlds.

### Continuation footprint coverage

Extend verified footprints to other common facilities and report remaining
opaque continuations by name.  Dynamic metadata must remain the safe default
for user callbacks whose upper bound is genuinely unknown.

### Dependency-bucket precision

Two datagram invalidations and a larger share of socket/reactor invalidations
come from supplier-bucket generation changes.  Determine whether those buckets
can be partitioned by direction, key or programme family without losing a
possible participant.

### Linear continuation work

Measure how often `and_then` extends a candidate without introducing another
alternative.  Seek less activation and graph bookkeeping within the same lazy
state, rather than a separate linear evaluator.

## Acceptance rules

A proof-engine optimisation must preserve:

- the same valid committed worlds;
- `Retry`, `Unknown` and certified negative proof semantics;
- speculative isolation of writes and effects;
- participant and occurrence identity;
- product and custody rules;
- fixed-seed replayability;
- agreement with the reference evaluator on validating scenarios.

A change is rejected if it merely moves work outside instrumentation, converts
an incomplete search into absence, or creates an I/O-only transaction path.
