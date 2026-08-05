# Speculative phase-integrity audit

This audit covers the built-in operation callbacks and committed effects in the
pre-v1 tree. Its purpose is narrow: a callback which may run during operation
construction, search, replay, backtracking or effect preparation must not mutate
retained semantic state or perform an irreversible host action.

The audit does not certify arbitrary callbacks supplied by applications. Public
`map`, `guard`, selector, matcher and facility-authoring callbacks
remain subject to their documented replayability and purity contracts.

## Scope

The source tree contains:

- built-in `map` transforms and `guard` builders across the portable and host-backed facilities;
- 58 built-in state-machine transition definitions, including the 25 Flow
  transitions and five generic socket-lifecycle transitions;
- six typed committed-effect kinds: interrupt, spawn, Closure close-reason,
  Flow notification, host-reactor control and Closure recovery claim.

Each site was reviewed according to the phase in which it runs and the identity
of every value it mutates or calls.

## Permitted callback behaviour

The following do not escape a losing speculative activation and are permitted:

- construction of fresh operation values and immutable result records;
- mutation of tables newly allocated by the callback itself;
- mutation of a copied managed-state value which is returned as a transition
  patch;
- creation of fresh dormant facility graphs inside a `guard` activation;
- monotonic allocator bookkeeping used solely to give fresh internal objects
  distinct identities.

The following are not permitted before commit:

- mutation of a Task, Lifetime, Scope, Closure or host handle which existed
  before the callback activation;
- consumption or clearing of a retained body, frame factory or ownership field;
- mutation of the current managed-state value rather than a returned copy;
- host registration, interruption, spawning, notification, closure or I/O;
- using search exhaustion or effect-preparation refusal as an irreversible fact.

## Findings and repairs

### Task spawn body consumed during speculative sequencing

`Task:_spawn_effect` previously cleared the retained task body while the spawn
right-hand operation was being explored. The effect now carries the Task as its owner.
Effect preparation only validates that a dormant body exists. After the managed-state
commit, discharge calls `Task:_take_spawn_body`, creates the runnable wrapper,
clears the dormant body and asks the runtime to allocate the committed fiber.
No body, wrapper factory or fiber frame is moved or allocated by speculative
search.

### Closure bookkeeping mutated by cancellation search

`Scope` cancellation previously wrote `closure_state.close_reason` from a
speculative callback. The write is now represented by the internal typed effect
`closure.close_reason`. It is discharged only after the cancellation and close
state have committed. The operation remains usable by a downstream transactional
`and_then`; no post-commit `wrap` is inserted into the transactional result path.

`state_for` also no longer caches the Scope Closure merely because a cancellation
operation was constructed. Active Closure execution installs that field in its
ordinary committed execution phase.

### Admission affiliated dormant Lifetimes during construction

`Scope:admit_op` now performs a read-only compatibility check. Runtime identity,
boundary attachment and the clearing of dormant construction topology are carried
by the LifetimeStore's typed committed consequence after the admission state has
been installed. Defeated, abandoned and never-performed admission values leave the
Lifetime dormant and unaffiliated. The transition re-reads the dormant construction
graph when it is performed, so a child added after operation construction is
included in the atomic admission rather than being stranded by an early snapshot.

### Cancellation exit nested the runtime cancellation object

Child-outcome conversion now recognises a runtime cancellation and constructs
`Exit.cancelled(cancellation.reason, cancellation.token)`. Parent Closure reports
therefore preserve the original reason identity and exact interrupt token.

### Stale spawn ownership fields

Spawn discharge no longer clears obsolete `owner.fn` or `owner.scope` fields.
The only ownership transfer is the explicit Task method
`_take_spawn_body(runtime)`. This keeps the post-commit protocol aligned with the
current Lifetime-backed Task representation.

### Speculative process labels

The process guard still creates a fresh dormant Process graph per activation,
which is intentional. Its public default label no longer incorporates a global
activation counter, so replay or defeat cannot be observed through gaps in later
process names. Fresh internal identity allocation remains diagnostic allocator
bookkeeping rather than retained application state.

## Transition review

All built-in transition callbacks either:

- return a read-only query result;
- return a newly constructed state value; or
- clone the current state before changing it.

The Flow transitions use `copy_state`, including rope cloning where byte content
is changed. Event queues clone their queue state before changing links or counts.
LifetimeStore transitions use `clone_state`, persistent-map replacement and
copied custody records. Socket lifecycle and dial transitions construct or copy
state records before writes. No built-in transition mutates the current managed
value in place.

Ready predicates and absence checks were reviewed separately. They read managed
or committed host facts and do not reserve, publish or mutate them.

## Effect review

Effect `key`, `merge` and `prepare` callbacks are read-only and non-yielding.
Their discharge behaviour is:

| Kind | Committed action |
| --- | --- |
| `interrupt` | raises the selected interrupt token |
| `spawn` | transfers one dormant Task body and creates the committed fiber |
| `closure.close_reason` | records retained Closure bookkeeping |
| `flow_changed` | notifies the host reactor of committed Flow state change |
| `host_reactor_control` | registers, retires or wakes a reactor entry |
| `closure.recovery_claim` | no host action; committed state carries linearity |

No effect preparation consumes ownership or changes host state. The spawn effect
is the only effect which transfers retained ownership, and that transfer now
occurs solely in discharge.

## Regression coverage

`tests/lifetimes/test_phase_integrity.lua` checks both production and reference
evaluators for:

- inert construction and defeat of admission;
- later admission of the same Lifetime by another runtime;
- defeat and reuse of one transactional spawn operation;
- exactly-once body transfer after commit;
- removal of stale spawn-owner field clearing;
- inert cancellation construction and defeat;
- committed close-reason bookkeeping;
- exact cancellation reason and token propagation.
