# Lifetimes, custody and settlement

`fibers` treats structured lifetime management as transactional custody recorded in a Region ledger. Scope policy decides how a boundary reacts to body completion, child failure, cancellation and unresolved settlement.

Advanced examples in this guide use named modules explicitly:

```lua
local fibers = require('fibers')
local Region = require('fibers.lifetime.region')
local policy = require('policy')
```


## Ordinary scope use

```lua
local fibers = require('fibers')

fibers.run(function(scope)
  local task = scope:spawn(function()
    return 'done'
  end, 'worker')

  assert(fibers.perform(task:await_op()) == 'done')
end)
```

A scope callback receives the scope. `fibers.spawn` targets the current scope; `scope:spawn` is the explicit form.

Raising forms:

```text
fibers.run
fibers.scope
Scope:run
```

return body values or raise after boundary accounting.

Checked forms:

```text
fibers.try_run
fibers.try_scope
Scope:try_run
```

return a `ScopeResult` containing success values or a structured report.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Obligation | Continuing responsibility admitted or created by a committed world. |
| Custody | Responsibility to resolve an obligation. |
| Authority | Permission to act through a handle. |
| Admission | Transactional entry into custody. |
| Movement | Atomic transfer of custody. |
| Borrow | Temporary authority without transfer of custody. |
| Seal | Refusal of new custody. |
| Claim | Exclusive authority to resolve an owned subtree. |
| Resolution | Discharge, failure or restoration of a claim. |
| Settlement | Protocol work undertaken after a claim commits. |

Custody and Lua reachability are not the same. Holding a reference does not necessarily mean the current scope owns or is authorised to use it.

## Scope surface

Principal methods include:

```lua
scope:spawn_op(fn, opts)
scope:spawn(fn, opts)
scope:admit_op(item_or_owned, from_owner)
scope:move_op(item, target_scope_or_region)
scope:offer_op(item, target_scope, terms)
scope:accept_op(filter)
scope:authorise_op(item, right)
scope:borrow_op(item, borrower_or_rights, rights_or_opts, maybe_opts)
scope:claim_op(item, purpose)
scope:resolve_op(claim, resolution)
scope:request_cancel_op(reason)
scope:seal_op(reason)

scope:cancel_requested_op()
scope:cancellation_op()
scope:sealed_op()
scope:done_op()
scope:owns_op(item)
scope:record_op(item)
scope:subtree_op(item)
scope:roots_op()
scope:inspect_op()
```

`scope:raw_region()` exposes the underlying Region for trusted facility code and APIs which explicitly require a Region owner.

## Admission and structured spawn

`Scope:spawn_op` constructs a Task, admits it to the Region and emits a post-commit spawn effect in one option.

```text
construct Task
+ admit owned Task
+ select spawn effect
+ return Task
```

If that option loses, the task does not start.

`scope:spawn` performs `spawn_op` immediately in the current fibre.

Custom lifetime-bearing values may be admitted as bare items or as `Region.Owned` specifications carrying settlement metadata.

## Atomic movement

Direct movement transfers a live root in one commit:

```lua
fibers.perform(source:move_op(item, destination))
```

Negotiated movement composes movement with synchronous consent:

```lua
fibers.perform(fibers.tensor({
  source:offer_op(item, destination, { role = 'session' }),
  destination:accept_op(function(offer)
    return offer.terms and offer.terms.role == 'session'
  end),
}))
```

A rejected offer rejects that candidate. It does not consume an unrelated offer.

Movement covers the complete owned subtree rooted at the item. A contained child cannot be moved independently.

## Region records and phases

A Region stores records containing fields such as:

```text
item
role
parent and children
settlement function and name
phase
claim metadata
settlement failure information
```

The relevant lifecycle is:

```text
live      available for movement or claim
claimed   exclusively held by a claim capability
failed    settlement failed and custody remains observable
absent    discharged or moved out of the Region
```

A live item has at most one owner.

The low-level Region surface includes:

```lua
region:admit_op(item_or_owned, from_owner)
region:release_op(item)
region:move_op(item, target_region)
region:claim_op(item, purpose)
region:resolve_op(claim, resolution)
region:discharge_claim_op(claim)
region:fail_claim_op(claim, err)
region:restore_claim_op(claim)
region:seal_op()

region:is_open_op()
region:changed_op(version)
region:owns_op(item)
region:record_op(item)
region:children_op(item)
region:subtree_op(item)
region:members_op()
region:roots_op()
region:snapshot_op()
region:live_op(item)
region:authorise_op(item, right, opts)
```

A bare Region records ownership truth. It does not itself know how to interrupt a task, flush a stream or close a host handle. Those behaviours are supplied by settlement protocols and scope policy.

## Authority and borrowing

A scope can prove authority for an owned or borrowed item:

```lua
fibers.perform(scope:authorise_op(item, 'read'))
```

Borrowing grants rights without transferring custody:

```lua
local borrow = fibers.perform(
  owner:borrow_op(item, borrower, { 'read' }, {
    name = 'temporary-reader',
  })
)
```

The borrow is itself an obligation in the borrower scope. Settling it releases the temporary authority. The original owner remains responsible for the underlying item.

Distinguish:

```text
move    custody changes owner
borrow  custody remains; temporary authority is granted
lease   compatibility-managed transactional right
claim   exclusive authority to settle custody
```

Authority enforcement is currently strongest at explicit endpoint and ownership seams, including Flow and Stream handles. It is not a general Lua object-capability sandbox.

## Claims

A claim is a fresh capability object tied to one Region, one root and its complete owned subtree.

Claim creation:

```text
verify live root
compute subtree closure
verify every member is live
create fresh claim capability
mark every member claimed
```

Only the original capability object can resolve the claim. Reconstructing its diagnostic fields does not confer authority.

While claimed, the subtree cannot be moved, released or claimed again.

Resolution kinds are:

```text
discharge   remove custody after successful settlement
fail        retain custody in failed phase with error information
restore     return the subtree to live custody
```

## Settlement protocol

Settlement starts only after the claim commits:

```text
transaction: claim subtree
post-commit participant work: run settlement option
transaction: resolve claim
```

Settlement may perform further options and may wait. It is not speculative cleanup inside a state transition.

A custom owned value can be constructed with:

```lua
local owned = Region.Owned.item(handle, function(ctx, record, claim)
  return handle:close_op(claim.reason)
end, {
  role = 'demo-handle',
  settle_name = 'demo-close',
})

fibers.perform(scope:admit_op(owned))
```

The settlement callback returns an `Op`. Merely constructing that option must not perform irreversible cleanup.

Use `Region.Owned.tree` for an item with explicit owned children and `Region.Owned.inert` when no settlement work is required.

## Failed settlement remains custody truth

A settlement failure occurs after the claim has committed. It cannot be rolled back as though the claim never existed.

The record remains owned in failed phase with diagnostic fields including the settlement error. Ordinary movement, release and duplicate claim remain blocked until policy explicitly restores or otherwise resolves it.

Central rule:

> Failed settlement is an unresolved obligation, not an exception erased during unwinding.

## Scope policy

The default nursery policy:

```text
monitors admitted task roots
seals on body completion or failure
on child failure, records the cause and requests body/sibling cancellation
waits for retained tasks
settles remaining roots while masked
completes only after every retained root is accounted for
```

```lua
fibers.run(function()
  fibers.spawn(function() error('worker failed') end)
  fibers.perform(wait_for_work_op())
end)
```

A supervisor isolates child failure according to its mode:

```lua
fibers.scope({
  policy = policy.supervisor({ child_failure = 'collect' }),
}, function()
  fibers.spawn(worker)
end)
```

Supported `child_failure` values are:

```text
fail_at_exit
collect
ignore
```

Policies also gate escape hatches:

```text
allow_unstructured   permit high-level fibers.spawn_raw
allow_outward_move   permit custody movement out of the scope
allow_admission      permit new admission
```

The low-level Region API remains available to trusted implementation code.

A custom policy may implement `try_run(scope, fn, driver)`. The supplied driver provides mechanisms such as monitor start, close, seal and root retirement; policy owns the boundary decisions.

## Principal laws

```text
Unique custody
  A live owned root has at most one Region owner.

Atomic admission
  Losing admission creates no custody and starts no work.

Atomic movement
  A complete subtree leaves one Region and enters another in one commit.

Seal monotonicity
  A sealed Region accepts no new custody.

Exclusive claim
  A claimed subtree cannot be moved, released or claimed again.

Explicit resolution
  A claim ends only through discharge, failure or restoration.

Failure retention
  Failed settlement remains represented in the ledger.

Borrow separation
  Borrowing changes authority, not custody.

Boundary accounting
  A scope does not complete while its policy retains unaccounted live roots.

Policy causality
  Cancellation induced by a failure does not replace the failure which caused it.
```

## Facilities above the lifetime layer

Task, Flow, Stream, Pool and host-backed handles define facility-specific settlement protocols but use the same Region and Scope mechanisms. Future lifetime abstractions should be derived from custody, authority, claims and policy rather than creating unrelated cleanup systems.
