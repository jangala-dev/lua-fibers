# Implementation internals

This document describes the active compact implementation. `../advanced/option-algebra.md` is the semantic contract. The copy-on-branch evaluator in `reference/fibers/internal/reference_machine.lua` is retained as a differential oracle; it is not the production path.

## Compact semantic kernel

```text
src/fibers/internal/kernel/ir.lua            inert primitive programmes and option footprints
src/fibers/internal/kernel/store.lua         versioned locations, speculative views and commit
src/fibers/internal/kernel/choice_order.lua  pure seed-derived branch permutations
src/fibers/internal/kernel/dependencies.lua pending components, retained-work validation and coordination
src/fibers/internal/kernel/frontier.lua     blocked-frontier classification and branch ordering
src/fibers/internal/kernel/adaptive_search.lua lazy memoisation, no-goods and retention policy
src/fibers/internal/kernel/activation.lua    request-local speculative activation paths
src/fibers/internal/kernel/machine.lua      closed-world trail-based proof search
src/fibers/internal/kernel/search_session.lua retained production-search lifecycle
src/fibers/runtime.lua      fibres, open-world scheduling and host boundary
```

`src/fibers/runtime.lua` is the supported embedding boundary. The remaining kernel modules are closed implementation details under `src/fibers/internal/kernel/`.

Current sizes are deliberately bounded:

```text
ir.lua                 about 400 lines
dependencies.lua     about 750 lines
frontier.lua            about 180 lines
adaptive_search.lua     about 560 lines
store.lua               about 670 lines
choice_order.lua        under 60 lines
machine.lua             about 1,470 lines
search_session.lua      about 450 lines
runtime.lua             about 1,400 lines
```

The boundaries are intended to map directly to a systems-language port:

```text
store    knows no fibres
machine  knows no host event loop
runtime  does not implement facility-specific transition semantics
```

## Option graph and primitive IR

The public option graph contains:

```text
always
primitive
choice
and_then
product(independent | interacting)
or_else
consequence
annotated occurrence
```

Public helpers elaborate to those forms. Options are ordinary immutable-by-convention Lua tables; the runtime does not mutate them. Static footprint caching is stored in a weak-key side table.

A dynamic `choice` occurrence receives an occurrence serial within its evaluator task. `choice_order.lua` derives a pure permutation from the runtime's `choice_seed`, epoch, pending generation, request identity, evaluator task identity and occurrence serial. The permutation consumes no process-global random state, so speculative rollback does not perturb later choices and the trail and reference evaluators can reproduce the same traversal.

`activation.lua` interns a small request-local tree of semantic progression tokens. Evaluator tasks carry one token. Structural descent adds lane or branch facts; primitive outcomes add observed-version facts; exchanges, claims and witnesses add the selected proof fact; and an `or_else` fallback includes the certified Retry interests and checks which opened it. An `and_then` result is addressed by the activation of its provisional predecessor outcome. Guard expansions remain in the existing request memo, keyed by the enclosing activation token rather than by reusable `Op` identity. The token tree is monotonic and outside rollback, while task references to tokens remain ordinary speculative evaluator state.

This permits the same progression to recover a guarded deadline after search reconstruction, while a different tensor lane, proof alternative or observed location version receives a fresh guard evaluation. Exact search-state identity includes activation information only where a continuation can observe it, preserving memoisation of guard-free duplicate branches.

Primitive facilities compile to records in `src/fibers/internal/kernel/ir.lua`:

```text
read
patch
claim
conditional_claim
machine_transition
witness_transition
version_wait
exchange
snapshot
```

Convenience constructors such as `IR.select` and `IR.admit` build ordinary claims.

A primitive programme cannot redefine:

```text
search ordering
product visibility
Retry or Unknown
rollback
validation
commit
```

### Compiled footprints

When a fibre performs an option, the runtime records a conservative footprint containing:

```text
possible exchange resources and roles
possible versioned locations and access modes
resource-wide observation or supply
option-node identities and kinds
dynamic-continuation marker
external-observation marker
```

During participant recruitment, the machine uses those footprints to prefer pending requests which may satisfy current intents. Footprints are an over-approximation and are not proof. Dynamic `and_then` continuations are marked conservatively.

`map` has no option-valued continuation.  `guard` and `and_then` may carry a
conservative continuation declaration produced by `Op.dependencies(...)`.
Unannotated callbacks remain opaque and therefore correct on the global slow
path.  Tests may enable `Runtime.new({ verify_dependencies = true })` to check
that an executed continuation is covered by its declaration.

For larger pending frontiers, `dependencies.lua` incrementally indexes
exchange roles, versioned locations, resource-wide dependencies and opaque
requests.  The runtime derives the connected component containing the focus and
passes only that conservative component to the evaluator.  The index is
activated and released with hysteresis so tiny frontiers retain the direct-scan
path.

## Versioned store

A location contains:

```text
integer identity
name
committed value
version
merge algebra
optional owner and apply callback
```

Current merge algebras are:

```text
replace
add
presence
finite_map
machine
```

The store supplies fixed sequential, independent-parallel and interacting-parallel composition rules for each algebra.

### Speculative views

Each selected root has a root view. Product lanes fork from their parent view. Sequential continuations retain the same view.

A view contains:

```text
observed value/version records by location
sparse staged deltas by location
root identity
product scope path
merged marker
```

The committed value is not copied merely because a view exists. Large facility values use persistent or path-copying internal structures so speculative successors share unchanged data.

### Product projection

All sibling changes participate in final-world consistency. For partial options, view projection enforces the product law:

```text
all
    constraining and neutral sibling changes are visible
    positive sibling supply is hidden

tensor
    compatible sibling supply is visible
```

For monotone claims, supply is selected by orientation. For serial machine transitions, the store compares readiness before and after each sibling step. A transition may declare `supply = 'none'` where explicit sequencing is required.

### Candidate collection and commit

When all selected roots complete, the store combines their root deltas in external composition mode and records one observed version per location.

Validation checks current location versions. Commit applies each combined delta, increments the location version and invokes the optional apply callback.

The active store assumes the runtime driver enters serially; it is not a parallel lock-free commit protocol.

## Trail-based search machine

`machine.lua` searches a selected map of pending perform requests with one focus request and a search limit.

Before general branching, the evaluator exhausts deterministic option work
and applies two certified reductions: an unambiguous binary exchange with no
possible unentered supplier, and a sole all-member non-supplying machine claim
with no possible unentered supplier.  Residual exchange branching uses the
smallest positive partner domain; claim groups use the smallest domain first;
participant recruitment prefers the request which can supply the greatest
number of current blocked intents.  `frontier.lua` contains this shared structural policy for both evaluators.

Its implementation returns:

```text
candidate or nil
refutation data
unknown boolean
```

These correspond to semantic `Hit`, `Retry` and `Unknown`. The production machine represents branch control as an explicit stack. On bounded `Unknown`, the runtime may retain that `SearchSession` and resume it from the exact branch position, provided a conservative dependency stamp still validates. The copy-on-branch reference evaluator restarts bounded searches.

### Numeric arenas

Dynamic search objects use monotonic integer identifiers:

```text
TaskId
GroupId
ViewId
IntentId
```

Tables keyed by those IDs act as arenas. IDs are not reused during one search.

Tasks carry:

```text
root request
current expression
continuation frames
view identity
product scope path
status
```

Product groups retain parent task and view, lane views, lane outcomes and completion count.

Product lane views are sparse and parent-linked.  Creating a lane does not copy
the parent observation map.  Reads walk the short parent chain; the first local
write promotes only that location into the lane.  On product completion, only
locally observed cells and local deltas are merged back into the parent.

### One rollback trail

The production machine mutates one search state and records undo entries in one trail. Current entry forms cover:

```text
field assignment
array append
```

Store observations, cell-value changes, patch insertion and patch-array
appends use those same field and array undo records.  The production evaluator
does not clone a complete view on first mutation.

A speculative branch records a trail mark. Backtracking restores that mark.

The same branch mechanism is used for:

```text
public choice alternatives
exchange partners
witness cursor alternatives
claim resolution order
participant inclusion or exclusion
preferred and fallback search scopes
```

The trail is implemented in Lua with parallel arrays. A systems port can use a compact tagged vector.

### Continuations and occurrence locality

`and_then` frames belong to the occurrence which produced their input. A provisional result may activate a new option in the same transaction. If the continuation later fails, the prior result binding and state are rolled back.

Product results preserve lane and nested row structure. Wraps are composed per lane and captured as immutable wrap vectors before speculative group state is rolled back.

### Linear exchange

Rendezvous puts and gets become linear intents with root and product ancestry. Same-root intents may match only when their first diverging product group is interacting. Cross-root intents may match when roles and resources are compatible.

A match remains provisional until both participant options and all continuations close.

### Claims and machine transitions

Claims are grouped by location and explored through the ordinary branch mechanism. Serial machine transitions are ordered by a search-assigned serial number and folded into the location's machine delta.

A partial machine transition which cannot proceed becomes an intent. Tensor siblings or recruited roots may supply it unless the transition declares `supply = 'none'`.

### Lazy witness cursors

A witnessed transition provides a cursor factory returning:

```lua
local cursor = {
  next = function()
    return next_candidate_or_nil
  end,
}
```

Each `next()` result is one candidate successor and packed result. The machine owns progression, rollback and exhaustion. Petri token bindings and Calendar slot choices use lazy cursors.

The older eager `enumerate` callback is adapted to a cursor for source compatibility; it should not be used for large search spaces.

### Refutation and `or_else`

Local query exhaustion does not by itself establish Retry. Refutation is composed only after option branches, witnesses, matches, claims and relevant participant choices are exhausted.

When a preferred `or_else` scope is refuted, the fallback branch receives:

```text
negative checks from the preferred refutation
preferred host interests for candidate validation and reporting
negative runtime epoch and pending-generation guards
```

If fallback also fails, the runtime reports the residual fallback interests rather than retaining discarded preferred waits.

## Runtime and open-world scheduling

`runtime.lua` owns:

```text
coroutines and current scope context
pending perform requests
scheduler order
participant request maps
machine selection and invocation
candidate validation and refresh
atomic commit orchestration
effect preparation and discharge
external feeds and interests
driver phase checks
```

The trail machine is selected by default. Use either:

```lua
Runtime.new({ machine = 'reference' })
```

or:

```sh
FIBERS_MACHINE=reference lua tests/run_all.lua
```

to select the copy-on-branch oracle.

### Scheduling boundary

New fibres are started in scheduler order. A closed positive world belonging solely to the newly entered request may commit immediately. Multi-participant worlds and absence-certified fallbacks are considered after currently runnable fibres have exposed their attempts.

This prevents a later-started background fibre from recruiting an older request through a non-preferred branch before that older request receives its own scheduling turn.

### Runtime statuses

`Runtime:run` and `Runtime:step` return statuses such as:

```text
found       at least one transaction committed
pending     more driver work or an external interest may make progress
quiescent   Retry was established with no actionable host interest
idle        no live or pending work remains
```

Budget exhaustion is represented as `tag = 'pending', kind = 'budget'` with `interests_incomplete = true`. There is no public `unknown` status tag in the current implementation.

### Validation and refresh

Before commit, the runtime checks:

```text
all participant requests still exist
observed location versions
preferred-side negative guards
runtime epoch and pending-participant generation for fallback candidates
resource-specific external absence checks
```

A stale positive or fallback candidate is discarded. Search is run again against current state; stale validation is never converted into Retry.

### Commit phases

```text
1. validate candidate
2. merge and prepare effects
3. install store deltas
4. increment runtime epoch
5. discharge effects
6. remove selected pending requests
7. resume selected fibres
8. apply participant wraps inside Runtime:perform
```

Perform, spawning and driver entry are restricted by runtime phases. Irreversible work is forbidden during search and effect preparation.

## External observations

Signal, EventQueue and Readiness are host-owned versioned facilities. `Runtime:external_feed` returns a capability bound to one runtime and one resource.

An exhausted external programme may attach:

```text
Interest              host-actionable wait description
absence_check         negative fact to validate before fallback commit
```

Delivery mutates only the bound resource, increments its location version and runtime epoch, then allows later driver entry to reconsider pending work.

Clock waits are pull-validated against `Runtime:now()`. A matured deadline invalidates a stale fallback even without feed delivery.

## Persistent facility data

The store treats committed values as opaque. Large facilities therefore use sharing internally:

```text
Flow       persistent measured byte deque
Region     layered persistent maps and immutable custody order
Petri      layered persistent place maps and copied touched token bags
Calendar   path-copying interval treap and persistent reservation index
```

The current data structures are Lua reference implementations. A native port may replace them while preserving transducer and delta semantics.

## Systems-language mapping

A direct port can use:

```text
immutable option and programme arenas
integer TaskId, GroupId, ViewId, IntentId and LocationId
vectors for tasks, groups, intents and active work
one tagged rollback trail
one tagged alternative stack or recursive search frames
compact location read and write sets
lazy index cursors
persistent facility roots
an outbox of prepared post-commit effects
```

Lua values, host callbacks and facility state roots can remain opaque handles at the kernel boundary.

## Verification

The supported suite runs the trail and reference machines through the same public API. Coverage includes:

```text
global exchange, claim and witness backtracking
nested product and continuation locality
Retry, Unknown and stale fallback validation
all/tensor supply laws
external interests and feeds
scope ownership and settlement
Flow and stream losing-branch safety
host readiness and bounded stepping
```
