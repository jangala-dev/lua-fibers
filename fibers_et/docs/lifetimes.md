# Lifetimes, custody and settlement

`fibers` treats continuing work and resources as obligations with explicit custody. A transaction establishes truth at commit; the lifetime system records which responsibilities remain afterwards.

Most users should work through `Scope`. `Region` is the underlying transactional ownership resource.

## Ordinary scope use

```lua
local fibers = require('fibers')

fibers.run(function()
  fibers.scope(function(scope)
    local task = fibers.spawn(function()
      return 'ok'
    end)

    assert(fibers.perform(task:await_op()) == 'ok')
  end)
end)
```

The ordinary contract is:

```text
Create lifetime-bearing things inside a scope.
The scope accounts for them before its boundary completes.
Move or borrow things explicitly when they cross a boundary.
Settlement failure remains visible.
```

`fibers.run` creates the root scope. `fibers.scope` creates a nested scope. `fibers.spawn` admits a task to the current scope and starts it only after admission commits.

Use `try_run` and `try_scope` when the boundary report is part of normal control flow. The raising forms call `:raise()` on that result.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Obligation | Continuing responsibility created, admitted or moved by a committed world. |
| Custody | Responsibility to resolve an obligation. |
| Authority | Permission to act through a handle. |
| Borrow | Temporary authority without moving custody. |
| Admission | Committed entry into custody. |
| Movement | Atomic transfer of custody. |
| Seal | Stop accepting new custody. |
| Claim | Exclusive authority to resolve custody. |
| Resolution | Discharge, failure or restoration of a claim. |
| Settlement | Resource-specific work which attempts to discharge custody. |

Custody and authority are intentionally separate. Retaining a Lua reference does not necessarily mean that the current scope is responsible for the object or authorised to use it.

## Scope operations

The principal scope surface is:

```lua
scope:spawn_op(fn, opts)
scope:admit_op(item_or_owned)
scope:move_op(item, target)
scope:offer_op(item, target_scope, terms)
scope:accept_op(filter)
scope:authorise_op(item, right)
scope:borrow_op(item, rights, opts)
scope:claim_op(item, purpose)
scope:resolve_op(claim, resolution)
scope:seal_op(reason)

scope:sealed_op()
scope:done_op()
scope:owns_op(item)
scope:record_op(item)
scope:roots_op()
scope:inspect_op()
```

`sealed_op` means no new custody may enter. `done_op` means the boundary has reached an accounted outcome; it does not imply success. `inspect_op` is intended for diagnostics and tests rather than ordinary programme logic.

### Admission and task spawning

`Scope:spawn_op` is a compound transaction:

```text
construct Task
admit owned Task to the Scope
emit the post-commit spawn obligation
return the Task
```

If the admission operation loses, the task is not started.

Custom obligations are admitted as ordinary items or as `Region.Owned` values carrying settlement information.

### Movement

Direct movement transfers a live root atomically:

```lua
fibers.perform(source:move_op(item, destination))
```

The item leaves the source and enters the destination in one committed world.

Negotiated movement combines transfer with synchronous consent:

```lua
fibers.perform(fibers.tensor({
  source:offer_op(item, destination, { role = 'session' }),
  destination:accept_op(function(offer)
    return offer.terms and offer.terms.role == 'session'
  end),
}))
```

A rejected offer rejects that candidate world. It does not consume and discard an unrelated offer.

## Region records and phases

A `Region` stores ownership records. A record may include:

```text
item
role
children
settlement protocol and name
phase
claim metadata
failure information
```

The relevant lifecycle is:

```text
live      admitted and available for movement or claim
claimed   exclusively held for resolution
failed    resolution failed and remains observable
retired   discharged; represented by absence from the live ledger
```

A subtree moves or settles as one owned structure. A live item has at most one owner.

The low-level Region surface includes:

```lua
region:admit_op(item_or_owned)
region:move_op(item, target_region)
region:release_op(item)
region:claim_op(item, purpose)
region:resolve_claim_op(claim, resolution)
region:restore_claim_op(claim)
region:discharge_claim_op(claim)
region:fail_claim_op(claim, err)
region:seal_op()

region:owns_op(item)
region:record_op(item)
region:subtree_op(item)
region:roots_op()
region:snapshot_op()
```

A bare Region maintains the ledger. It does not know how to cancel a task, flush a stream or close a host handle. Those behaviours belong to settlement protocols and scope policy.

## Authority and borrowing

A scope can prove authority for an owned or borrowed item:

```lua
scope:authorise_op(item, 'read')
```

Borrowing grants rights to another scope without transferring custody:

```lua
owner:borrow_op(item, borrower, { 'read' }, {
  name = 'temporary-reader',
})
```

The borrow is itself an owned obligation in the borrower scope. When the borrower settles, the temporary authority is released. The original owner remains responsible for the underlying item.

A useful distinction is:

```text
move    responsibility changes owner
borrow  responsibility remains; temporary authority is granted
lease   compatibility-managed right over a resource fact
claim   exclusive authority to resolve custody
```

Authority enforcement is incremental. Facilities which expose safe endpoint handles, such as Flow and Stream, are the main current users of the authority seam. Resource authors should not assume that Lua reachability alone is a sufficient future authority model.

## Claims and settlement

Settlement runs after a claim commits:

```text
live root
  -> claim_op
claimed subtree
  -> run settlement protocol operations
  -> resolve claim
retired, failed or restored subtree
```

This ordering matters. Settlement may itself perform transactions and wait. It is not speculative cleanup inside resource evaluation.

Resolution kinds are:

```text
discharge   settlement succeeded; release custody
fail        settlement failed; retain the failed record
restore     return the claimed subtree to live custody
```

The original claim object is the authority to resolve the claim. A diagnostic claim identifier is not sufficient.

### Custom owned values

Advanced facilities may construct an owned item:

```lua
local owned = fibers.Region.Owned.item(handle, function(ctx, record, claim)
  return handle:close_op(claim.reason)
end, {
  role = 'demo-handle',
  settle_name = 'demo-close',
})

fibers.perform(scope:admit_op(owned))
```

The settlement function returns an `Op`. It may wait and compose transactional work. It must not carry out external cleanup while merely constructing the operation.

Use `Region.Owned.inert(item)` only when no settlement work is required.

## Failure remains ownership truth

A settlement failure occurs after the claim has committed, so it cannot be rolled back as though the claim never happened.

The record remains owned in failed phase, with diagnostic information such as:

```text
phase = "failed"
settlement_failed = true
settlement_error_message = ...
```

The item is not silently released. Ordinary movement, duplicate claim and duplicate settlement remain blocked until policy explicitly restores or otherwise resolves it.

This is the central failure rule:

> A failed settlement is an unresolved obligation, not an exception which disappeared during unwinding.

## Scope boundary policy

Structured concurrency is policy over the lifetime calculus.

The default nursery policy monitors owned tasks while the body is running. A child failure atomically seals the scope, records the cause, interrupts the body and requests sibling cancellation. Successful body return seals admission and waits for retained children; body failure seals, cancels and joins them. Cleanup and settlement run masked, and the boundary completes only after every retained root has been accounted for.

```lua
fibers.run(function()
  fibers.spawn(function() error('worker failed') end)
  fibers.perform(wait_for_work_op()) -- interrupted by the child failure
end)
```

A supervisor isolates child failures from the body and siblings:

```lua
fibers.scope({
  policy = fibers.policy.supervisor({ child_failure = 'collect' }),
}, function()
  fibers.spawn(worker)
end)
```

Supervisor `child_failure` modes are `fail_at_exit`, `collect` and `ignore`. Reports retain observed child exits and failures even when the collecting supervisor returns successfully.

Policies also gate escape hatches. The default policy rejects high-level `fibers.spawn_raw`. `allow_unstructured = true` permits it explicitly. `allow_outward_move = false` prohibits `Scope:move_op` and negotiated offers from moving custody out of that scope; the low-level `Region` API remains available to trusted implementation code.

A custom policy may implement `try_run(scope, fn, driver)` and own the complete boundary algorithm. The supplied driver exposes `run`, `start_monitor`, `begin_close`, `seal` and `retire_roots`; these are mechanisms rather than nursery decisions. Policies receive `on_child_exit`, `on_cancel_requested`, `on_body_exit` and `result` callbacks when they delegate to `driver.run`.

The task monitor is created lazily on first admission. Membership changes and task exits are delivered as committed lifecycle consequences to a private queue. The Region ledger remains authoritative: the queue wakes policy code, but does not replace custody records.

## Principal laws

```text
Unique custody
  A live owned root has at most one Region owner.

Atomic admission
  Losing admission does not create custody or start admitted work.

Atomic movement
  Custody leaves the source and enters the target in one commit.

Seal monotonicity
  A sealed Region does not accept new custody.

Atomic closure
  Closure seals the Region and captures the retained task roots in one
  transaction. Concurrent admission is either included or loses.

Boundary accounting
  A scope does not complete while it retains an unaccounted live task root.

Policy causality
  Nursery-induced cancellation exits do not replace the child or body failure
  which caused closure.

Exclusive claim
  A claimed subtree cannot be moved, released or claimed again except through
  its claim authority.

Explicit resolution
  A claim ends only through discharge, failure or restoration.

Failure retention
  Settlement failure remains represented in the ownership ledger.

Borrow separation
  Borrowing changes authority, not custody.

Boundary accounting
  A scope does not report completion while unaccounted live roots remain under
  its policy.
```

## What remains above this layer

Facilities such as streams, pools and tasks define their own settlement protocols but use the same custody verbs. Experimental forms such as phases, escrow or tombs should also be derived from this layer rather than introduce unrelated lifetime mechanisms.
