# Execution-frontier kernel

This is an implementation document. The canonical application laws are defined in [Options](../guide/options.md) and [Lifetimes](../guide/lifetimes.md).

Fibers has one transactional evaluator. It executes immutable operation graphs against a mutable speculative store, records the exact frontier reached by blocked work, and commits one validated world at a time.

## Responsibilities

The kernel owns:

- speculative operation execution;
- rollback through a first-write journal;
- `Hit`, `Retry` and `Unknown` outcomes;
- active and latent execution frontiers;
- versioned invalidation;
- candidate validation;
- effect preparation and discharge;
- participant continuation;
- lifetime consequences selected by the transaction.

Facilities do not implement a second scheduler or proof engine. They provide executable leaves and compose them with the public operation algebra.

## Immutable operation graph

The closed graph contains:

```text
always
primitive leaf
choice
guard
map
and_then
product
or_else
consequence
```

Constructing an operation is inert. Mutable activation state belongs to one perform request or retained search session, never to the reusable operation value.

`and_then` sequences two operations transactionally. Value-dependent residuals are explicit guards:

```lua
first:and_then(Op.guard(function(value)
  return operation_for(value)
end))
```

Static shape is derived mechanically from the graph. It may guide ordering and conservative grouping, but it has no authority to prove absence.

## Search state

A Search contains:

- the Lua coroutine retaining branch and continuation state;
- a speculative store rooted in committed managed state;
- a rollback journal;
- activation-local guard residuals;
- witness cursors;
- the current execution frontier;
- selected consequences and participant results.

A genuine alternative opens a journal mark. First writes and list extensions are recorded once per mark. Backtracking restores the speculative store, activations, cursor positions and proof state together.

## Search outcomes

A search yields one of three semantic outcomes:

- **Hit** — a coherent candidate world exists;
- **Retry** — present absence has been established from complete, versioned facts;
- **Unknown** — the configured work or capacity boundary was reached before either conclusion.

`Unknown` never enables `or_else`.

## Products

`each` and `together` share one product mechanism.

- `each` requires every lane to be independently supportable. Sibling positive supply is hidden.
- `together` permits compatible sibling supply, including internal rendezvous and hand-off.

Sibling constraints remain visible in both modes. Product results retain lane order even though search order is free to vary.

## Execution frontiers

When a request blocks or completes an exact refutation, the kernel publishes a frontier containing the facts that can change that conclusion. These may include:

- location versions;
- exchange offers and demands;
- resource generations;
- external observations and host interests;
- unresolved witness or decision state;
- latent dependencies retained from a discarded preferred branch;
- a completed Retry certificate and its snapshot.

The Engine indexes Proofs by the resources and membership buckets they mention. A relevant admission, commit, timer maturity or external delivery marks the affected roots dirty. Unrelated roots remain reusable.

The governing invariant is:

> Every fact capable of changing a blocked or refuted operation is recorded in its frontier or conservatively invalidates that frontier.

## Bounded execution

A soft quantum suspends the Search coroutine and preserves its journal, branch position and cursor state. A later Engine turn resumes the same Search if its Proof snapshot remains valid.

Hard depth, total-work and trail limits return `Unknown` and dispose of unresumable state. Capacity exhaustion must never be converted into `Retry`.

## Candidate commitment

A candidate is committed in this order:

1. validate participants and managed observations;
2. revalidate negative observations and preferred-absence gates;
3. prepare the complete effect batch;
4. calculate every final managed value without changing committed state;
5. install all prepared values and versions using raw kernel writes;
6. discharge selected effects, including Lifetime admission and retirement;
7. resume participants and apply their continuations.

The installation phase invokes no user or facility callback. A calculation
failure occurs before the first committed write and leaves all locations
unchanged. Once installation completes and effect discharge begins, ordinary
rollback is no longer possible. Discharge failure is therefore a fatal runtime
condition with structured diagnostic information.

## Exchange frontiers

Pending participants are recruited in response to an active demand. A recruited
root records the demands which caused its admission, so search resolves the
resulting connected witness graph rather than enumerating arbitrary subsets of
pending roots. This preserves completeness: every committed participant
component has a spanning tree rooted at the focus request, and each non-root
participant has a first exchange edge to the component already admitted.

A closed frontier contains only exchange intents and has no pending participant
which may supply another partner. Closure is conservative: incomplete or dynamic
shape information keeps the frontier open. Once closed, the kernel may establish
exact structural facts:

- unequal put and get counts for one resource prove absence;
- an intent with no compatible partner proves absence;
- a degree-one edge may be propagated without a checkpoint;
- a large frontier with no perfect matching proves absence.

For a large closed resource, the exchange scan initially represents its graph as
complete. The first incompatible edge materialises exact adjacency; a completely
compatible frontier therefore requires only its put and get arrays. One complete
matching is tried as a preferred branch. If later continuations reject that
branch, ordinary exhaustive search remains available, so the matching suggestion
does not remove an admissible world.

## Ordering accelerators

The kernel may use fail-first ordering, partner ranking and matching suggestions.
Such mechanisms may select which complete alternative is tried first. They may
not:

- remove an admissible alternative;
- establish `Retry` without an exact structural refutation;
- bypass validation;
- weaken frontier completeness.

Performance metadata may add work but must not remove a possible world.

## Identity and deterministic order

The mutable kernel records semantic state rather than an administrative history. Internal tasks, groups, segments, intents, candidates and participants refer to one another directly. Numeric registries are not used to recover objects already reachable through the current Search or Engine graph.

Determinism comes from lawful local order:

- pending roots follow Engine admission order;
- operation branches and product lanes follow immutable graph order;
- Search tasks and intents follow append order or activation lineage;
- exchange and witness alternatives use their explicit local order;
- machine transitions carry the serial order required by their algebra;
- lifetime closure follows custody and reverse-admission order.

Local ordinals remain only where an object moves between collections or where the algebra requires a stable tie-break. Proof facts use resource, request and activation objects directly. Diagnostics may assign presentation labels lazily, but those labels have no search, proof or commitment authority.

## Module boundary

The implementation has five state-owning roles:

```text
fibers/runtime.lua
  Runtime     fibers, ready queue, public phases and errors

fibers/internal/engine.lua
  Engine      pending requests, arbitration, Proof indexing and commit authority

fibers/internal/kernel/search.lua
  Search      one direct or retained speculative execution

fibers/internal/kernel/journal.lua
  Journal     speculative managed state, observations and rollback

fibers/internal/operation.lua
  Operation   immutable nodes, executable leaves and conservative shape
```

`Candidate`, `Proof` and `Activation` are private values used by those owners. They do not own scheduler loops or independent lifecycles. Candidate representation, validation, effects and settlement remain invisible to Runtime. Host delivery and blocking policy live under `fibers.embed`; lifetime custody and closure live under `fibers.lifetime`.

## Core invariants

1. One runtime has one commit authority.
2. Operation construction is inert.
3. Speculative callbacks may be replayed or abandoned.
4. Every provisional write belongs to one live speculative segment.
5. Rollback restores all search-visible mutable state.
6. `Retry` depends only on complete versioned facts.
7. `Unknown` carries no absence authority.
8. A candidate is validated immediately before commitment.
9. Losing transactional task admissions do not start their bodies.
10. Every live lifetime has one custodian.
11. Closure state moves monotonically.


## Execution-frontier detail

The following expands the frontier model used by search, invalidation and `or_else`.

This document explains the retained proof mechanism used to preserve the public option laws. Begin with [Options](../guide/options.md) for the application-facing account.

An execution frontier is the persistent, versioned account of where a pending operation reached and what could change its status.

### Structural shape and executed facts

Fibers derives a conservative shape from the immutable operation graph. Shape is useful for ordering and initial grouping, but cannot prove that an operation is absent.

Proof-relevant information is produced only by execution. A leaf or composite records the facts it actually observed before blocking, yielding or completing a refutation.

### Frontier contents

A frontier may contain:

- observed managed locations and their versions;
- exchange roles, values and compatibility buckets;
- external resource versions and host interests;
- unresolved decision or witness state;
- active waits still represented by the operation;
- latent membership dependencies from a preferred branch discarded by `or_else`;
- a complete Retry result and the snapshot needed to validate it.

Active facts continue to represent live waits. Latent facts do not keep a refuted branch operational, but they invalidate the refutation if a compatible participant later appears.

### Publication and indexing

Frontiers are published when search blocks, suspends at a soft quantum or establishes exact Retry. The runtime indexes each frontier by the facts capable of changing it.

Examples:

- writing one cell dirties roots observing that location;
- admitting a rendezvous sender dirties compatible receivers;
- advancing a clock to a recorded deadline dirties the corresponding timer root;
- delivering one external event dirties roots observing that feed;
- admitting an unrelated participant leaves independent roots unchanged.

Broader invalidation is sound but less efficient. Narrower invalidation is unsound.

### Retained search

A bounded search session retains its coroutine, speculative store, rollback journal, guard activations, witness cursors and branch position. The session also retains its frontier snapshot.

On the next driver turn:

1. the snapshot is validated;
2. an unchanged session resumes directly;
3. a relevant change disposes of the session and starts a fresh search;
4. an exact unchanged Retry may be returned without replaying search.

### `or_else`

A preferred branch may open its fallback only after exact present absence is established. The frontier records all active and latent facts capable of invalidating that proof. `Unknown` caused by a work or capacity boundary never opens the fallback.

### Authoring obligation

Trusted leaves must report complete frontier information for every way their result could change. Facility tests should compare incremental frontier reuse with full re-execution over generated small worlds. Both paths must admit the same committed worlds.
