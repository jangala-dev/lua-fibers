# Implementation internals

This document is for contributors changing the runtime, resource protocol or compound facilities. `algebra.md` owns semantic definitions; this document explains where those semantics are implemented.

## Repository layout

```text
fibers.lua                 top-level convenience API
fibers/atoms/              canonical operations and standard resources
fibers/kernel/             transaction search, runtime, retry and effects
fibers/internal/           trusted implementation helpers
fibers/host/               host adapters and non-blocking handle families
fibers/scope/              scope policy support
fibers/stream/             stream backends and pumps
fibers/*.lua               compound facilities
examples/                  executable usage examples
tests/                     semantic and integration tests
benchmarks/                validating microbenchmarks
```

Placement rule:

```text
atom       one resource algebra or canonical operation machinery
kernel     generic interpretation, search, commit or host boundary
internal   private trusted helper with no supported public contract
compound   ordinary Lua composition over atoms and kernel facilities
```

Do not add a kernel primitive merely because a facility is important. `Task`, `Scope`, `Queue`, `Flow` and `Stream` remain compounds.

## Operation representation

`fibers/atoms/op.lua` constructs the seven canonical term kinds:

```text
always
primitive
choose
and_then
product
or_else
consequence
```

Derived forms are normalised at construction:

```text
never   -> empty choose
map     -> fused and_then/always where possible
guard   -> delayed and_then with attempt-local cache metadata
all     -> independent product
tensor  -> interacting product
emit    -> consequence
```

Post-result transforms and defeat obligations use one annotation representation around the underlying term. They are not candidate-world constructors.

Raw operation tables are not a public extension mechanism. All internal code should use the canonical fields produced by the constructors.

## Runtime lifecycle

`fibers/kernel/runtime.lua` owns:

- fibre registration and runnable state;
- current runtime and current scope dynamic context;
- perform attempts;
- driver phase checks;
- transaction search invocation;
- commit preparation and application;
- external feed delivery;
- bounded cursors and runtime status;
- fatal integrity failure state.

A normal perform cycle is:

```text
fibre calls perform(op)
  -> create attempt occurrence
  -> suspend fibre
  -> transaction net searches active roots
  -> select and prepare a closed world
  -> apply resource journals
  -> discharge outcome effects
  -> mark selected fibres runnable
  -> resumed perform applies post-result transforms
```

Only the currently resumed runtime fibre may call `perform`.

## Transaction-net search

`fibers/kernel/transaction_net.lua` implements the semantic search. It contains:

- deterministic local reduction;
- continuation frames for `and_then` and annotations;
- unordered choice arbitration and enumeration;
- independent and interacting product construction;
- rendezvous and premise closure;
- retry-proof accumulation;
- `or_else` fallback validation;
- bounded-search cursor creation and reuse;
- selected and losing occurrence accounting.

Search results are:

```text
Hit(world)
Retry(proof)
Unknown(cursor, reason)
```

The solver must not manufacture `Retry` from exhaustion of a work budget. Unknown search state remains resumable and cannot open `or_else`.

### Local reduction

Terms which require no resource or partner search are reduced locally. The local and general reducers share continuation handling so that `and_then`, post-result transforms and defeat annotation semantics cannot drift.

Guard construction is cached per dynamic occurrence and perform attempt. Backtracking must not repeatedly call the same guard callback.

### Choice arbitration

`fibers/kernel/choice_arbiter.lua` owns committed branch rotation. The transaction
net asks it for an order identified by runtime, fibre and dynamic choice
occurrence. That order is cached in the perform attempt and is therefore stable
across backtracking and bounded cursor suspension.

A candidate attempt records every selected choice occurrence on the speculative
trail. Rollback removes those records. `World.from_attempt` copies the surviving
selections, and `World:commit` advances the arbiter only after resource journals
have been applied. Search, retry, stale validation and prepare refusal never
advance arbitration state.

Unkeyed state is held by operation node and occurrence path. Explicit keys use a
separate per-fibre namespace and allow reconstructed operation nodes to share a
rotation. Keyed choices remain nested arbitration boundaries rather than being
flattened by choice normalisation.

Protocol priority must be represented by `or_else`, not by branch position.
Internal examples include mailbox send before concurrent closure, immediate pool
retirement before deferred retirement, and stream terminal state before advisory
backend readiness.

### Occurrences and defeat

A reusable operation becomes a dynamic occurrence when entered by an attempt. Defeat obligations belong to the occurrence, not to each candidate world it produces.

An occurrence may be:

```text
latent
armed in competition
selected
permanently defeated by a selected competitor
```

Backtracking, retry, validation conflict, fallback and Unknown are not defeat.

## Candidate worlds

A candidate proposal may contain:

```text
packed participant values
resource records
rendezvous requirements
premises and substitutions
effect set
post-result transforms
managed observations
fallback retry evidence
```

Candidate cloning must preserve semantic identity without copying more than necessary. Resource records are cloned through the resource kind where provided.

A selected combination is closed only when all rendezvous and premise requirements are resolved and all resource records merge.

## Resource integration

The generic resource layer is split between:

```text
fibers/kernel/resources.lua
  solver-facing resource evaluation and premise integration

fibers/kernel/resources/protocol.lua
  sparse record merge, projection, preparation and application

fibers/kernel/resources/result.lua
  Ready | Premise | Retry

fibers/kernel/resources/resolution.lua
  exhaustive premise solutions and deferred proof construction

fibers/kernel/resources/proposal.lua
  candidate contribution container
```

The kernel never switches on resource names. A kind table owns its record algebra.

Resource evaluation contexts share the lazy retry builder in `fibers/kernel/retry_builder.lua`. Successful paths retain compact observations; a full `RetryProof` is materialised only when the path actually retries or an exhaustive premise proof is needed.

## Premises

Premises defer resource-specific allocation until the solver can see the relevant combined world.

`fibers/kernel/premise_helpers.lua` provides shared utilities for:

- stable premise ordering;
- provenance-aware resource record views;
- product lane and mode information;
- once-only proof contributions;
- substitution result packing.

A premise resolver returns every current solution in semantic preference order and a proof under which that enumeration is exhaustive.

The independent/interacting distinction is enforced through record provenance:

```text
independent sibling
  may constrain a solution but may not positively supply it

interacting sibling
  may positively supply a fact or rendezvous partner
```

## Retry and validity

`fibers/kernel/retry.lua` represents proof-carrying retry. It records:

- observed generation-stamped frontiers;
- host-actionable interests;
- optional diagnostic observations;
- permanent structural retry where explicit.

`fibers/kernel/validity.lua` supplies managed mutable facts. Capability reads register observations through the active context. Capability writes invalidate the appropriate frontiers.

Cursor and fallback reuse is pull-validated: the runtime checks recorded generations when considering a saved result. There is no global invalidation broadcast graph.

`fibers/kernel/interest.lua` is deliberately separate from validity. An interest says how a host may make progress; it is not the evidence which justifies retry.

## Effects and commit

Effect kinds and sets live under `fibers/kernel/effect/`.

A commit proceeds conceptually as:

```text
1. validate selected observations and fallback proofs
2. merge and prepare resource records
3. prepare selected commit effects and losing defeat effects
4. apply prepared resource journals
5. discharge the complete outcome-effect batch
6. make spawned or awakened work runnable
7. resume selected participants
8. apply post-result transforms inside perform
```

No user fibre may run in the middle of the effect batch.

Effect preparation is side-effect-free. Effect discharge occurs after resource commit and is currently fatal on failure because rollback is no longer possible.

## External resources and hosts

`Signal`, `EventQueue`, `Clock` and `Readiness` are ordinary resources. Runtime-bound producer authority is implemented by `fibers/kernel/external_feed.lua`.

A host interest may carry the exact feed required to update an external resource. Hosts do not gain generic mutation authority merely by holding the consumer resource.

`fibers/internal/unsafe_external_mutation.lua` is reserved for trusted implementation paths already inside the runtime boundary. New ordinary host integration should use feeds.

`fibers/runner.lua` wraps `Runtime:run` with host blocking. Host adapters live under `fibers/host/`; descriptor helpers are paired with their host family.

## Scopes and settlement

`fibers/atoms/region.lua` is the ownership resource. `fibers/scope.lua` and `fibers/scope/policy.lua` provide the ordinary structured-lifetime compound.

Task admission is transactional:

```text
construct Task
admit its owned record to Region
emit post-commit spawn
```

Settlement helpers under `fibers/internal/settlement.lua` claim roots, run resource-specific settlement operations under the policy, and resolve or retain failure.

The policy monitor is an internal Task created lazily when a scope first acquires a task root. Region admission and movement effects, together with task-completion effects, append committed records to a private `EventQueue`. The monitor drains this queue in batches and checks current ownership before accounting for an exit. This avoids repeatedly rebuilding a choice over every retained child while preserving Region as the source of custody truth.

Do not embed task cancellation, stream close or other resource-specific settlement behaviour into Region itself.

## Flows and streams

`fibers/flow.lua` implements transactional byte reservoirs and endpoint state. `fibers/stream.lua` combines two flows. Host-backed stream code under `fibers/stream/` owns backend adaptation, leases and pump tasks.

The irreversible boundary is the pump task's backend call. It occurs only after readiness commits and outside search. Reservoir leases retain capacity while bytes are offered to the host and are later acknowledged, returned or failed transactionally.

The current reservoir permits one active lease at a time to preserve ordering.

## Error and phase policy

Recoverable application errors belong in fibre code and are represented through normal Lua errors protected by `fibers.pcall` or through operation results.

Errors in trusted search, resource or commit machinery are fatal. The public driver boundary restores its phase bookkeeping, marks the runtime failed and re-raises. A failed runtime is not reusable.

Important phase restrictions:

```text
search callbacks       non-yielding, no external side effects
resource machinery     non-yielding, no committed mutation before apply
effect preparation     non-yielding and side-effect-free
effect discharge       non-yielding trusted runtime work
host callbacks          serialised through the driver boundary
post-result transforms  run in resumed fibre context and may perform again
```

## Testing changes

Every semantic change should have a focused test before or with the implementation change.

Expected test classes include:

```text
operation laws and derived forms
choice and defeat occurrence lifecycle
all/tensor provenance
Retry versus Unknown
fallback proof invalidation
resource merge and stale preparation
premise exhaustiveness
external feed authority and wake
scope ownership and settlement failure
flow losing-branch safety
host readiness and timeout races
```

Run the full suite after local tests:

```sh
lua tests/run_all.lua
```

Optional host tests should skip cleanly when their dependency is unavailable.

## Performance-sensitive paths

The main allocation-sensitive areas are:

- operation construction and derived `map` chains;
- candidate cloning;
- product lane combination;
- premise solution enumeration;
- retry-proof materialisation;
- saved cursor validation;
- flow delimiter scans and reservoir leases;
- task and scope admission.

Keep retry capture lazy. Do not allocate a full proof on a successful resource path. Preserve single-item fast paths where measurements support them.

Benchmark changes with both the complete scale-1 suite and focused higher-scale product, fallback or rendezvous cases. The benchmark harness validates semantics before timing.

## Adding behaviour

Before adding a module, decide which layer owns it:

```text
new mutable transactional truth       resource
new combination of existing truth     compound facility
new host condition                     external resource plus interest/feed
new runtime obligation                 typed effect kind
new lifetime behaviour                 settlement protocol or scope policy
new operation syntax                   only if it cannot be derived without a
                                       semantic loss
```

The preferred direction is to keep the kernel small and make new facilities ordinary compositions over the existing algebra.
