# Execution frontiers

An execution frontier is the persistent, versioned account of where a pending operation reached and what could change its status.

## Structural shape and executed facts

Fibers derives a conservative shape from the immutable operation graph. Shape is useful for ordering and initial grouping, but cannot prove that an operation is absent.

Proof-relevant information is produced only by execution. A leaf or composite records the facts it actually observed before blocking, yielding or completing a refutation.

## Frontier contents

A frontier may contain:

- observed managed locations and their versions;
- exchange roles, values and compatibility buckets;
- external resource versions and host interests;
- unresolved decision or witness state;
- active waits still represented by the operation;
- latent membership dependencies from a preferred branch discarded by `or_else`;
- a complete Retry result and the snapshot needed to validate it.

Active facts continue to represent live waits. Latent facts do not keep a refuted branch operational, but they invalidate the refutation if a compatible participant later appears.

## Publication and indexing

Frontiers are published when search blocks, suspends at a soft quantum or establishes exact Retry. The runtime indexes each frontier by the facts capable of changing it.

Examples:

- writing one cell dirties roots observing that location;
- admitting a rendezvous sender dirties compatible receivers;
- advancing a clock to a recorded deadline dirties the corresponding timer root;
- delivering one external event dirties roots observing that feed;
- admitting an unrelated participant leaves independent roots unchanged.

Broader invalidation is sound but less efficient. Narrower invalidation is unsound.

## Retained search

A bounded search session retains its coroutine, speculative store, rollback journal, guard activations, witness cursors and branch position. The session also retains its frontier snapshot.

On the next driver turn:

1. the snapshot is validated;
2. an unchanged session resumes directly;
3. a relevant change disposes of the session and starts a fresh search;
4. an exact unchanged Retry may be returned without replaying search.

## `or_else`

A preferred branch may open its fallback only after exact present absence is established. The frontier records all active and latent facts capable of invalidating that proof. `Unknown` caused by a work or capacity boundary never opens the fallback.

## Authoring obligation

Trusted leaves must report complete frontier information for every way their result could change. Facility tests should compare incremental frontier reuse with full re-execution over generated small worlds. Both paths must admit the same committed worlds.
