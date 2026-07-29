# Kernel design

This document defines the stable design of the Fibers production kernel. The
option algebra in [`../advanced/option-algebra.md`](../advanced/option-algebra.md)
is the public semantic contract. This document states how the kernel preserves
that contract while searching, proving absence, validating and committing.

The production evaluator and the copy-on-branch evaluator under
`reference/fibers/internal/` must remain independent implementations. The
reference evaluator is the semantic oracle for finite differential tests; it is
not a production path.

## 1. Design statement

Fibers is a transactional option evaluator with two execution tiers:

```text
direct transactional reduction
        │
        ├── candidate found
        ├── durable Retry established
        └── ambiguity or absence reasoning required
                    │
                    ▼
          promoted proof component
                    │
                    ├── reveal relevant dynamic residuals
                    ├── maintain finite alternative domains
                    ├── propagate availability and local absence
                    ├── activate or_else fallback when justified
                    └── return candidate, Retry or Unknown
```

The kernel is organised around this distinction:

```text
not currently ready
    ≠
unavailable under current speculative assumptions
    ≠
durably unavailable in the managed world
    ≠
not yet determined
```

`or_else` makes these distinctions observable. A fallback may run only after
the preferred scope has a sound local proof of absence. A root `Retry` may be
returned only when the relevant negative proof can be expressed as durable,
revalidatable managed-world facts.

The kernel is not intended to be a general-purpose constraint solver. It uses a
lightweight direct path for ordinary operations and promotes only the proof
component which needs explicit alternatives, dynamic revelation or absence
reasoning.

## 2. Stable boundaries

The following boundaries are normative:

```text
option algebra   defines admissible committed worlds
IR               defines the closed trusted primitive substrate
ledger           owns speculative transactional state
proof machine    constructs candidates and negative proofs
runtime          validates and commits serially
host             provides versioned external observations and effects
reference        independently checks finite semantics
```

The hierarchical ledger, activation identity, rollback trail, candidate
validation and serial commit protocol remain the trusted foundations. Search
heuristics and specialised proof procedures may change provided they do not
alter the set of admissible committed worlds.

## 3. Declarative semantic basis

For an activated option occurrence `E` in a managed world `Σ`, write:

```text
⟦E⟧Σ
```

for the set of candidate worlds in which `E` may commit. A candidate world may
contain:

```text
selected participant attempts
synchronous exchange matches
provisional and committed location summaries
custody changes
negative validation facts
selected commit and defeat consequences
participant-local wrap trees
```

A production success is sound only when:

```text
Hit(candidate)  implies  candidate ∈ ⟦E⟧Σ
```

A production retry is sound only when:

```text
Retry(certificate)  implies  ⟦E⟧Σ = ∅
while certificate remains valid
```

This meaning is independent of:

- choice seed;
- branch order;
- propagation order;
- proof-component promotion;
- a specialised matching or capacity procedure;
- the traversal order of the reference evaluator.

The semantic root outcomes remain:

```text
Hit(candidate)
Retry(certificate)
Unknown(reason)
```

`Unknown` means that the implementation has not established either success or
absence within the available budget or provider completeness. It is never
absence and must never enable fallback.

## 4. Managed and speculative worlds

The managed world contains durable runtime facts:

```text
Σ = {
    committed location values and versions,
    pending request identities and attempts,
    dependency-index generations,
    external resource versions and epochs,
    host readiness and time observations,
    search-policy identity
}
```

A speculative branch extends the managed world with:

```text
B = {
    selected alternatives,
    recruited participants,
    provisional ledger segments,
    provisional rendezvous values,
    guard and sequencing activations,
    local absence assumptions,
    staged consequences,
    rollback trail
}
```

Speculative state is not a durable fact merely because it was used to prove a
candidate. Rollback restores the preceding speculative world exactly.

## 5. Negative proof objects

The kernel distinguishes three forms of negative information.

### 5.1 Conflict explanation

A conflict explanation states why one alternative or speculative branch cannot
complete. It may cite:

- selected alternatives;
- provisional values;
- recruited participants;
- ledger observations and writes;
- product visibility;
- dynamic residual activations;
- managed-world facts.

A conflict explanation is branch-local. It supports rollback, diagnostics and
optional session-local learning. It does not by itself enable fallback or
justify a root `Retry`.

### 5.2 Local absence proof

A local absence proof states that one activated option occurrence has no
admissible candidate under the current speculative assumptions.

It records:

```text
the occurrence and activation
all speculative assumptions on which absence depends
conflict explanations covering every eliminated alternative
closure over exact, conditional and relevant opaque support
product visibility and sibling-supply mode
```

A local absence proof may enable an `or_else` fallback inside the same
speculative candidate. It is not necessarily durable outside that candidate.

For example, a primary may be locally absent because another selected product
lane has provisionally consumed the only compatible resource. That is a valid
fallback gate inside the candidate, but not a statement that the resource is
absent from the committed world.

### 5.3 Durable retry certificate

A retry certificate contains only facts which the runtime can revalidate:

```text
location versions
request identities and attempts
dependency-bucket generations
external versions and readiness epochs
timer deadlines and clock observations
search-policy identity
```

A durable certificate may support:

- a root `Retry`;
- retained-session validation;
- host interest parking;
- commit-time validation of a fallback gate.

A local absence proof may be projected into a durable certificate only when
every assumption is either:

1. a revalidatable managed-world fact; or
2. represented within the selected candidate and validated with it.

Whole local absence proofs are not globally interchangeable. The kernel may
share canonical atomic managed-world facts, but each option occurrence retains
its own activation, visibility and speculative assumptions.

## 6. Direct reduction and promotion

### 6.1 Direct path

Ordinary operations should remain on the lightweight direct path. This includes,
where unambiguous:

- `always`;
- exact cell and version reads;
- one exact primitive transition;
- one exact rendezvous;
- deterministic `map`, `wrap` and static `and_then` progression;
- products requiring no unresolved competition or fallback;
- a selected guard whose residual reduces deterministically;
- exact host observations already available.

The direct path should not allocate generic domain, watcher, explanation or
provider records merely because the promoted layer exists.

### 6.2 Promotion triggers

The affected proof component is promoted when direct reduction encounters one
of the following:

- unresolved `choice`;
- `or_else` requiring proof of preferred-side absence;
- competing viable suppliers;
- relevant opaque guard support;
- product-wide compatibility or allocation;
- provisional value rejection requiring explanation;
- a global infeasibility proof;
- repeated negative reasoning which can be watched or shared.

Promotion is one-way for the lifetime of that speculative component. The
machine must not repeatedly convert a live component between direct and
promoted representations.

### 6.3 Promoted component

A promoted component owns, conceptually:

```text
activated occurrences
finite alternative domains
watchers and a propagation queue
local proof and explanation records
decision and rollback state
a component work budget
```

Implementations may use compact arrays, cursors and integer identifiers. The
conceptual records do not require materialising the whole stable option graph.

A promoted component may conclude:

```text
Candidate(plan, local gates)
LocalAbsence(proof)
Open(blockers)
Unknown(reason)
```

The runtime converts these to root `Hit`, `Retry` or `Unknown` only after the
appropriate projection and validation rules have been applied.

## 7. Occurrences, activations and dynamic residuals

An option object is inert and reusable. Semantic identity belongs to an
activated structural occurrence, not to host-language object identity.

Reusing one `Op` value in two product lanes creates two occurrences with two
activation identities. Defeat obligations, guard preparation and provisional right-hand operations remain occurrence-sensitive.

### 7.1 Guards

A guard begins as an opaque activation-local residual.

Its stable contract is:

- the builder is evaluated at most once for a valid activation;
- the returned option remains fixed while that activation and its tracked
  observations remain valid;
- the builder is immediate and non-yielding;
- irreversible effects and unmanaged transactional mutation are forbidden;
- applications must not depend on the relative preparation order of distinct
  guards;
- a relevant losing alternative may be prepared speculatively when necessary
  to establish support or absence.

A guard may be revealed when:

- its alternative is selected;
- it may supply an exposed demand;
- its opacity prevents closure of an `or_else` primary;
- a trusted proof procedure requires its residual.

After revelation, the memoised residual is treated as an ordinary option graph.
Its exact dependency metadata replaces the former conservative opaque plan for
that activation.

### 7.2 Transactional sequencing

Before an `and_then` prefix produces values, only the prefix is active. The
right-hand operation is structurally present but dormant. Its known dependencies
remain available to conservative component construction, while it cannot supply
an active demand until the prefix succeeds.

When the prefix provisionally produces values:

1. a child sequencing activation is created;
2. the right-hand operation is activated in the same lane-local ledger segment;
3. any guard within that operation receives the prefix values directly as
   callback varargs;
4. a revealed guard residual contributes its actual dependency plan;
5. propagation resumes before unrelated opaque decisions are made.

If the right-hand operation rejects the provisional world, its conflict
explanation includes the prefix decisions, delivered values and ledger
assumptions on which that rejection depends.

## 8. Dependency indexing and proof scope

The dependency index defines the sound scope within which absence may be
proved. Metadata is conservative and phase-sensitive.

```text
unopened guard
    opaque dynamic classification

revealed guard
    exact residual dependencies

and_then before prefix completion
    prefix is active; structurally known right-hand dependencies remain dormant

activated right-hand operation
    retained prefix observations plus its structural or revealed dependencies

dormant or_else fallback
    no active supplier dependency in the primary scope

enabled fallback
    fallback dependencies plus watchers for the primary gate
```

After revelation, obsolete conservative metadata is removed and the affected
dependency generation advances. Retained certificates which depended on the
former closure are invalidated.

A preferred scope may be declared locally absent only when it is closed under
all admissible support:

```text
every exact pending supplier is included or excluded by proof
every conditional supplier is represented by a live constraint
every relevant opaque supplier is revealed or prevents closure
every external supplier has a durable negative fact or actionable interest
```

Narrowing dependency metadata is permitted only where the residual is fixed for
its activation. Reindexing must never remove a genuine current supplier.

## 9. Alternative domains and propagation

An unresolved promoted choice owns a finite domain of structural alternative
occurrences. An alternative is conceptually:

```text
opaque      residual not yet revealed
viable      currently admitted by known constraints
eliminated  excluded by a conflict explanation
```

Rollback may restore an earlier state. Within one branch, elimination is
monotone.

The promoted machine processes deterministic reductions and watched changes to
a fixed point before arbitrary branching. A watcher may:

- eliminate an alternative;
- force the sole remaining alternative;
- request revelation of an opaque residual;
- update an exposed demand's supplier set;
- establish local absence;
- report `Unknown` where its analysis is incomplete.

The initial design need not maintain a universal support graph for every
operation. It must maintain enough watched state to determine:

- whether a domain still has a viable alternative;
- whether an exposed demand has a possible supplier;
- whether opacity prevents closure;
- whether an `or_else` primary is locally absent;
- whether a specialised proof provider applies.

Where a known support is ruled out, the promoted machine records one support
elimination consisting of the affected demand or alternative, the excluded
support and its local certificate. Exchange-value incompatibility, stale choice
pruning and provider conclusions use this common negative vocabulary. The
implementation need not materialise a universal support graph.

Where ambiguity remains after propagation, the machine may use fail-first and
least-constraining heuristics. Such heuristics affect work only; they do not
change semantics.

## 10. `or_else`

For:

```text
primary:or_else(fallback)
```

`primary` has semantic priority over `fallback`.

### 10.1 Preferred candidate

If the primary has an admissible candidate, the fallback remains dormant.

### 10.2 Preferred remains open

If the primary has no candidate yet but retains any viable, conditional or
relevant opaque support, the complete expression remains open. Blocking and
incomplete search do not enable fallback.

### 10.3 Preferred is unknown

If a search budget or trusted provider prevents the primary from being closed,
the complete expression is `Unknown`. The fallback remains dormant.

### 10.4 Preferred is locally absent

When every admissible preferred alternative has been eliminated and the proof
scope is closed, the kernel constructs a local absence proof and activates the
fallback under that gate.

The fallback activation identity is derived from the `or_else` occurrence, its
parent activation and a stable local gate epoch. It is not derived from the
serialised representation of the proof or certificate.

A fallback candidate carries the local gate. Candidate validation checks that:

- durable managed facts cited by the gate remain valid;
- speculative assumptions cited by the gate are still represented by the same
  selected candidate;
- no relevant opaque or external supplier has appeared;
- every participant remains on the same pending attempt.

### 10.5 Runtime arbitration is component-scoped

The serial runtime may have several pending roots. Positive-before-fallback is
not a global priority rule across those roots. Once the runnable frontier is
visible, the driver partitions pending requests by conservative dependency
components and arbitrates each component independently:

- a positive candidate in the same component precedes its fallback;
- `Unknown` in the same component keeps that fallback dormant;
- positive or `Unknown` work in an independent component does not delay it.

This preserves local fallback liveness: a perpetually ready unrelated fibre
cannot starve a certified fallback. Component construction remains
conservative. Dependencies are derived from the actual operation graph; an
unopened guard remains opaque and therefore cannot justify a narrower proof scope. Observing a Task,
Scope, Dial, resolver family or similar Lifetime terminal state also contributes
a directional causal dependency on pending work within that Lifetime's Scope.
Producer operations do not thereby become mutually dependent; they are recruited
only when an actual observer could be advanced by them.

The rule narrows scheduling, not proof. A fallback still carries and validates
the same local absence gate before commit.

### 10.6 Root retry

If both preferred and fallback scopes are locally absent, the root may return
`Retry` only when the complete local proof can be projected into a durable
certificate. Otherwise the result remains open or `Unknown`.

Operationally:

```text
fallback enabled
    if and only if
primary domain is soundly and locally closed
```

This is not `choice`, timeout or a try-once probe.

## 11. Products and ledger visibility

The hierarchical ledger remains the sole representation of speculative managed
state.

Each selected request receives a root segment on first transactional access.
Product lanes receive child segments; sequential right-hand operations retain their
lane-local segment. Segments contain sparse location summaries and materialised
values only where needed.

Visibility follows the option algebra:

```text
different root          full compatible contribution
interacting sibling     full compatible contribution
independent sibling     constraining contribution only
unrelated segment       hidden
```

Under `each`, positive sibling supply is hidden, but sibling constraints remain
visible. Under `together`, compatible positive sibling supply is visible.

A local absence proof inside a product must record the applicable visibility
mode. A proof derived under `each` cannot be reused as though it had considered
`together` sibling supply.

Product lanes join their summaries in stable lane order. Candidate collection
joins root summaries in stable root order. The ledger does not decide search
order, fibre scheduling or facility semantics.

## 12. Primitive IR and location algebras

Trusted facilities compile to the closed primitive IR before search. The
production and reference evaluators consume the same canonical primitive
programmes while retaining independent speculative-state implementations.

The built-in location algebras remain authoritative for:

- cloning summaries;
- appending sequential changes;
- joining external, independent and interacting summaries;
- applying a summary to a value;
- projecting the constraining part of a sibling summary;
- deriving directional supply information.

Neither the proof machine nor the ledger independently switches on facility
patch kinds. New algebras require explicit sequential and parallel laws.

IR metadata is a conservative dependency description, not a proof of presence
or absence. Dynamic residual revelation may refine metadata for one fixed
activation.

## 13. Specialised negative proof providers

The kernel may use specialised procedures for semantic structures already
present in the option graph, such as capacity-one matching or bounded resource
capacity. These are proof providers, not alternate commit engines.

A provider may issue a negative result only when its model is a certified
over-approximation of every possible success world admitted by the current
scope. Relevant visible, conditional, opaque, pending and external suppliers
must therefore be included, revealed or conservatively represented.

Providers should return checkable witnesses wherever practical.

Examples include:

```text
matching failure
    a demand subset whose possible supplier capacity is too small

capacity failure
    a required quantity exceeding a certified available bound

value incompatibility
    an exact producer-consumer activation pair rejected by a fixed right-hand operation
```

All exact negative providers use one production interface: produce a typed
witness, verify that witness against the same closed component, then return the
verified certificate through the ordinary retry path. Provider-specific fields
do not appear in candidates or retry certificates.

The central kernel verifies the witness before using it to eliminate an
alternative or establish local absence. An incomplete or ineligible provider
returns `Unknown`, never absence.

The first stable provider obligations are:

- soundness over a documented eligible fragment;
- conservative treatment of opaque support;
- an explanation for every negative conclusion;
- bounded work;
- differential testing against exhaustive finite cases.

General clause learning, parity solving and internal component decomposition
are not required by this design. They may be introduced later only with a
separate soundness argument and evidence from repeatable application workloads.

## 14. Optional session-local learning

The kernel may retain narrowly scoped incompatibilities discovered during one
valid search session. For example, when a particular producer-consumer pairing
delivers a value which a fixed guarded residual rejects, the corresponding edge may
be marked incompatible for the same activation and observation epoch.

Such learning is valid only while:

- the same producer and consumer activations remain live;
- the same memoised residual remains fixed;
- every cited managed and external observations remain current.

Learned facts are branch or session state, not durable retry facts. They are
bounded and discarded or invalidated with their assumptions.

General conflict clauses and non-chronological backtracking are optional future
optimisations, not part of the stable semantic design.

## 15. Budgets and `Unknown`

The runtime imposes both per-session and aggregate driver-cycle limits.

Session limits may cover:

```text
search work
decision depth
live trail entries
promoted domains
residual revelations
provider work
retained learning state
```

Driver-cycle limits cover aggregate work across all new and resumed sessions
and all focus plans attempted by one runtime step. A nominal per-session limit
must not be multiplied silently by trying many roots.

Budget checks belong at existing accounting boundaries rather than every helper
call. When a limit is exhausted, the result records the responsible resource
and remains `Unknown`.

A retained session resumes only while its participants, observations,
dependency generations, external epochs and policy identity remain valid.

## 16. Validation and serial commit

A complete candidate records:

```text
selected participant attempts
packed participant results
observed versions
combined ledger summaries
one optional absence gate
selected consequences and defeat obligations
participant wrap trees
```

The absence gate is the sole candidate representation of fallback justification.
It contains the managed-world epoch, pending-frontier generation and precise
negative checks required by the selected fallback world. The production and
reference evaluators use the same gate shape.

Before commit, the runtime verifies:

- every participant still waits on the same attempt;
- observed locations retain their versions;
- durable negative facts remain true;
- local fallback assumptions remain represented by the candidate;
- external observations and deadlines remain valid;
- prepared effects still admit the candidate;
- ledger summaries remain compatible.

Commit remains serial:

```text
1. validate participants, observations and negative gates
2. prepare the complete consequence batch
3. apply each location summary once
4. advance versions and mirrors
5. discharge commit and defeat consequences
6. remove selected requests
7. resume fibres with raw packed results
8. run participant-local wraps in returning perform calls
```

A validation failure performs no partial commit. Proof procedures propose
candidate worlds; they never bypass the ledger or commit protocol.

## 17. Production layout

The production kernel is organised under:

```text
src/fibers/internal/kernel/
    machine.lua          direct reduction, promotion and proof orchestration
    ledger.lua           segments, projection, product joins and collection
    algebra.lua          authoritative built-in location algebras
    domain.lua           promoted domains and lazy primitive cursors
    certificate.lua      durable facts and negative validation
    dependencies.lua     exact, opaque and phase-sensitive proof scope
    search_session.lua   resumable proof state and per-session budgets
    ir.lua               canonical primitive programmes and structural metadata
    supply.lua           conservative supply classification
    path.lua             activation and product-provenance paths
    trail.lua            speculative rollback journal
    choice_order.lua     reproducible heuristic ordering
    instrumentation.lua  unstable structural diagnostics
```

`src/fibers/runtime.lua` owns pending-request lifecycle, aggregate budgets,
session retention, validation, serial commit and host parking.

The principal boundaries are:

```text
ledger       knows no fibres or search order
algebra      owns every location-summary law
machine      knows no host event loop
runtime      knows no facility-specific transition semantics
providers    cannot commit state
reference    shares semantics and IR, not production proof machinery
```

## 18. Required invariants

The production kernel must preserve the following.

### Semantic safety

1. A fallback is activated only from a closed local absence proof.
2. `Unknown` never enables fallback.
3. A root `Retry` contains only durable revalidatable facts.
4. Branch-local assumptions do not escape as durable facts.
5. Every eliminated promoted alternative has a conflict explanation.
6. A relevant opaque support prevents closure until revealed or conservatively
   represented.
7. Search heuristics do not alter admissible committed worlds.
8. Reusing an `Op` object does not merge semantic occurrences.
9. A guard builder is evaluated at most once per valid activation.
10. Dynamic dependency refinement never removes a genuine current supplier.
11. An incomplete specialised provider returns `Unknown`, not absence.

### Transactional safety

12. Every provisional write belongs to one live ledger segment.
13. Rollback restores ledger, domain, activation and proof state exactly.
14. `each` and `together` retain their distinct sibling-supply laws.
15. Every candidate validates participant attempts and observed versions.
16. Every selected fallback gate is validated.
17. Consequences are prepared before commit and discharged only through the
    serial commit sequence.
18. Validation failure performs no partial commit.

### Operational safety

19. Exact ordinary operations are not promoted unnecessarily.
20. A promoted component reaches a deterministic propagation boundary before
    arbitrary branching.
21. Aggregate runtime work is bounded by the configured cycle budget.
22. Retained sessions resume only while their validation facts remain current.
23. Shared negative facts are atomic and invalidated by precise generations.
24. Specialised negative witnesses are centrally checked.
25. Session-local learning is scoped to exact activations and observations.

## 19. Assurance

The reference evaluator remains independently exhaustive and copy-on-branch. It
implements the same candidate-world, fallback and retry semantics but does not
share the production ledger, domain, propagation or provider implementation.

Differential tests compare:

- committed values and participant results;
- `Hit`, `Retry` and `Unknown`;
- retry interests and negative validation;
- guard evaluation counts;
- commit and defeat consequences;
- validation behaviour.

They do not compare production-specific search counters.

Generated finite tests should establish:

```text
every production Hit is admitted by the reference evaluator
every production Retry is a reference Retry
no production Retry corresponds to a reference Hit or Unknown
changing a cited fact invalidates the relevant certificate
irrelevant world changes do not invalidate a precise certificate
rollback restores the prior proof frontier exactly
specialised negative witnesses agree with exhaustive enumeration
```

Structural performance tests should preserve the direct path and cover guarded
supplier search, fallback batches, opaque waiter isolation, allocation failure
and value-dependent incompatibility. Search work and allocation counts are more
reliable gates than small wall-clock differences.

## 20. Conditional completeness

For a fixed managed world, unbounded search is expected eventually to return
`Hit` or `Retry` only when all of the following hold:

- the reachable activation graph is finite;
- every relevant choice domain is finite;
- the recruitable request set is finite;
- no new requests or external changes occur during the proof;
- every speculative callback terminates and is stable for its tracked inputs;
- every trusted provider terminates and is complete over its eligible fragment;
- propagation and branch selection are fair;
- rollback is exact.

This is a conditional semantic completeness claim, not a performance claim.
Where these conditions do not hold, the kernel may remain open or return
`Unknown` under a configured budget.

## 21. Summary

The stable kernel rule is:

```text
execute directly where possible
promote only where necessary
prove absence locally
certify Retry durably
validate and commit serially
```

Fibers remains a transactional option machine rather than a general solver.
The promoted proof layer exists to preserve the semantic distinction between a
blocked world, a locally unavailable world, a durably absent world and an
incomplete search. `or_else` is the operation which makes that distinction
observable, so absence proof, validation and invalidation are central kernel
responsibilities.
