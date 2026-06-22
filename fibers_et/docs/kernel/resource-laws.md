# Resource laws

`fibers` resources participate in transaction search by contributing candidate
worlds, waits, journals, and prepared commits.  Resource protocol code is
trusted runtime code, not user callback code.  User Lua belongs at algebra
boundaries such as `map`, `and_then`, `guard`, `wrap`, and `with_nack`, or in
small helpers that are explicitly derived from those boundaries.

## Value opacity

User values are opaque by default.  A resource may pass, store, or return an
ordinary Lua table without the solver traversing or copying its keyed fields.
Only solver-internal structures, such as option packs and product rows, are
structural values.

This means that a table sent through a channel or written to a cell is the same
user value at the other side, including keyed fields and nested tables.


## Result locality

Deferred algebraic continuations are local to the result that installed them.
For `p:and_then(f)`, `f` receives the values produced by `p`, even when `p` is
inside `all`, `tensor`, or an internally closed rendezvous.  Product options
combine lane results only after lane-local deferred continuations have consumed
their own lane values.

This is what lets higher-level protocols, such as lifetime handoff, be written
using ordinary value-blind channels plus `and_then`, instead of specialised
rendezvous matching in the solver.

## Resource evaluation

A resource option should have a fixed meaning in the resource's own language.
For example:

```lua
cell:read_op()
cell:write_op(value)
region:reassign_op(item, target)
queue:next_op()
```

Resource evaluation must not call arbitrary user predicates, match functions, or
update functions.  User interpretation belongs in ordinary Op composition.  For
example, a cell increment is written as `read_op():and_then(...)` followed by
`write_op(...)`; the function runs at the protected `and_then` boundary, not inside
the cell resource protocol.


## Observation validation

Resource evaluation must not make unrecorded observations of mutable runtime,
resource, or host state.  Such state must be represented by managed validity
facts from `fibers.kernel.validity`, and resource code must read those facts
through their capability methods.

Examples:

```lua
local value = scalar:get(ctx)
local item = queue:peek(ctx)
local present = map:contains(ctx, key)
local owner = claim:owner(ctx, slot)
clock:observe_before(ctx, deadline)
```

Each read records the relevant stamp on the current observer when bounded search,
prepared-world retention or debug revalidation needs one.  The same read is cheap
when no observer is active.

World observation validation answers a different question from resource
preparation: it decides whether the facts observed while constructing a
candidate world still hold.  `prepare` still validates that a selected resource
journal can commit.

It is legal to observe a coarser fact than strictly necessary, for example an
opaque epoch for a complex driver.  It is not legal to omit a fact that could
change the result of the search.

## Journals

A resource record is a tentative journal for one candidate world.  It must obey:

```text
clone(record)
  preserves the record's meaning

merge_seq(a, b)
  represents sequential composition

merge_par(a, b)
  represents independent lane composition, or rejects incompatible journals

project(resource, record, query)
  reports the base state overlaid with the tentative record
```

If a resource cannot lawfully merge two journals, it should reject the merge.  It
must not partially merge and recover by side effect.

## Prepare and apply

`prepare` is pure.  It may validate that the record is still fresh and may return
a prepared commit description, but it must not mutate resources, call host
arrival feeds, discharge effects, spawn work, or otherwise perform irreversible
work.

`apply` is the resource's state-changing commit action.  It receives only a
prepared record whose validation has already succeeded.

The intended law is:

```text
prepare followed by apply realises the projected committed state
```

## Effects

Effect payloads are immutable obligations.  An effect kind's `merge`
function should be pure: it returns a fresh merged payload, or one of its inputs
only if that input will not be mutated.

Effect `prepare` is also pure.  It may validate and produce a prepared
discharge record.  Discharge happens only after resource commit.

## External arrivals

External facts enter through runtime-bound producer capabilities, such as the
feed returned by `Runtime:signal`, `Runtime:queue_source`, or
`Runtime:readiness`.  These feeds update managed validity facts and bump the
corresponding stamps through the capability methods.  Solver cursors discover
staleness by pull validation when they are resumed.

Host/source arrival is an external driver boundary.  It is not valid from a
fibre, resource protocol code, effect preparation, or effect
discharge.
