# Transactional scope management

`Scope` is the ordinary lightweight container for lifetimes.  It is also the
place where the library's lifetime calculus becomes usable: custody, movement,
sealing, claim and settlement are gathered behind one small boundary.

```lua
fibers.scope(function(scope)
  local task = fibers.spawn(function()
    return 'ok'
  end)

  local value = fibers.perform(task:await_op())
end)
```

`Region` remains the ownership atom.  `Task`, `Stream` and `Scope` are compound
facilities built from the atom kit.  `Scope` uses `Region` as its ledger and
small scalar facts for `sealed_op` and `done_op`; richer observation belongs in
future compounds such as Mirror, not in core Scope.

For the laws that govern this facility, see `docs/scope_laws.md`.

This file is the detailed API note.  For the shorter user-facing guide, see
`docs/scope.md`.  For the broader design account, see
`docs/lifetime-calculus.md`.


## The common contract

Ordinary users should be able to remember this:

```text
Create lifetime-bearing things inside a scope.
They will be settled when the scope exits.
If something cannot be settled, the error remains visible.
Move or borrow things explicitly when they must cross the boundary.
```

The deeper contract is:

```text
admit      take custody
move       transfer custody atomically
seal       stop new custody
claim      take exclusive resolution authority
resolve    discharge, fail, or later tomb the claimed obligation
observe    explain the ledger
```

The current public surface implements custody, movement, sealing, claim, resolution, minimal authority and borrowing. Transitional aliases for the old scope vocabulary have been removed so the calculus has one name for each relation.

## Scope entry and ambient constructors

`fibers.scope(fn)` creates an inline scope, makes it current for the running
fibre, runs the body, seals the scope, retires remaining roots according to the
scope policy, and restores the previous current scope.

`fibers.spawn(fn)` uses the current scope.  Raw unstructured fibres remain
explicit through `fibers.spawn_raw`.

```lua
fibers.scope(function()
  local task = fibers.spawn(function()
    return 7
  end)
end)
```

Safe stream acquisition also uses the current scope unless an explicit owner is
provided.  The friendly `fibers.stream(backend, opts)` helper performs the safe
open operation and returns the owned stream handle.

## Region lifecycle

A Region record has an explicit lifecycle:

```text
live     admitted and owned by the Region
claimed  exclusively held for settlement or another resolution purpose
failed   settlement/resolution failed and remains observable
retired  discharged; represented by absence from the live ledger
```

The principal Region commands are:

```lua
region:admit_op(item_or_owned)
region:move_op(item, target_region)
region:seal_op()
region:claim_op(item, purpose)
region:resolve_claim_op(claim, resolution)
region:restore_claim_op(claim)
region:discharge_claim_op(claim)
region:fail_claim_op(claim, err)
region:owns_op(item)
region:record_op(item)
region:roots_op()
region:snapshot_op()
```

A bare Region only maintains the ledger.  It does not know how to cancel a task,
flush a stream, reap a process, or close a file.  Those behaviours belong in
settlement protocols and policy layers.

## Scope custody operations

`scope:admit_op(item_or_owned)` admits an owned handle or `Region.Owned` tree into
the scope's Region.

`scope:move_op(item, target)` atomically transfers a live root to another scope or
Region.  Negotiated movement is expressed through `offer_op`/`accept_op`.

`scope:claim_op(item, purpose)` claims a live root for explicit resolution.

`scope:resolve_op(claim, resolution)` resolves the claim.  The supported phase-two resolutions are `discharge`, `fail`, and `restore`.

`scope:seal_op(reason)` seals the underlying Region. `scope:sealed_op()` is the composable fact for observing that boundary.

`scope:done_op()` commits when the scope has reached an accounted outcome. It resolves to a small outcome table and does not carry body return values. `scope:inspect_op()` is the diagnostic snapshot for tests and tools.

## Task spawning

`Scope:spawn_op` is now a compound over admission:

```text
create Task handle
admit owned Task into this Scope
emit spawn effect after admission commits
return the Task handle
```

If the admitting transaction loses, the task is not started.

The lower-level `Task.spawn_op(region, ...)` remains available for implementers,
but ordinary structured code should use `scope:spawn` or `fibers.spawn`.

## Negotiated custody offer

A negotiated custody offer is a rendezvous over an atomic custody move:

```lua
fibers.perform(fibers.tensor({
  from:offer_op(task, to, { role = 'worker' }),
  to:accept_op(function(offer)
    return offer.terms and offer.terms.role == 'worker'
  end),
}))
```

A filtered `accept_op` rejects the candidate world when the offer does not match.
It does not consume and discard the wrong offer.  The ownership move and the
receiver's consent commit in the same world or not at all.

## Settlement and failed resolution

Scope settlement is policy work, not ordinary user API.  The policy claims an
owned root, runs settlement protocols masked, and resolves the claim with
`discharge`.  Compound authors who need the raw operation can use
`fibers.internal.settlement.retire_item_op(scope, item, reason)`, but user code
should normally rely on `fibers.scope` or `fibers.run` to account for roots.

If a protocol fails after the claim commits, Region records the subtree in
`failed` phase.  A failed settlement is therefore retained as truth:

```text
phase = "failed"
settlement_failed = true
settlement_error_message = ...
```

Scope itself does not emit a lifecycle event stream.  The ledger is the source
of truth; `sealed_op`, `done_op`, and `inspect_op` are the small observation
surface.  A future Mirror compound may provide richer observation.

Scope no longer carries a core lifecycle event stream.  Richer observation should
be derived by a future mirror facility from Region facts and boundary outcomes.

## Policies

Structured concurrency is policy over the lifetime calculus, not the calculus
itself.

The default policy driver lives separately from the calculus-facing `Scope` methods.
It seals on exit, observes task-root exits concurrently, requests cancellation
after body or child failure, retires roots, and fails if child or settlement
errors remain.  A supervisor policy may isolate child failures.  A future phase policy
can seal at a phase boundary, move declared carry-forward obligations, release
borrows, and tomb unresolved failures.
