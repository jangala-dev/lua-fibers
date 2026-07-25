# Lifetimes, custody and settlement

`fibers` treats structured lifetime management as transactional custody recorded in a Region ledger. Scope policy decides how a boundary reacts to body completion, child failure, cancellation and unresolved settlement.

Advanced examples in this guide use named modules explicitly:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local Region = require('fibers.region')
local policy = require('fibers.policy')
```


## Ordinary scope use

```lua
local fibers = require('fibers')

fibers.run(function(scope)
  local camera_task = scope:spawn(function()
    return 'opening shot complete'
  end, 'opening-camera')

  assert(fibers.perform(camera_task:await_op()) == 'opening shot complete')
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
fibers.perform(cinematic:move_op(camera_handle, gameplay))
```

Negotiated movement composes movement with synchronous consent:

```lua
fibers.perform(Op.tensor({
  lobby:offer_op(player_session, match, { role = 'player-session' }),
  match:accept_op(function(offer)
    return offer.terms and offer.terms.role == 'player-session'
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
parent and ordered children
settlement protocol and name
admission order for roots
phase and claim metadata
settlement request, force and completion progress
settlement failure information
```

The relevant lifecycle is:

```text
live      available for movement or claim
claimed   exclusively held by a claim capability
failed    settlement is incomplete and custody remains observable
absent    discharged or moved out of the Region
```

A live item has at most one owner. Child order is semantic: children are declared in ownership or acquisition order and settle in the reverse order. Independent roots are retired in reverse admission order.

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

`restore_claim_op` and manual `discharge_claim_op` apply to pristine low-level claims. Once settlement has begun, a claim cannot be restored, and it cannot be discharged until the settlement driver has recorded every member as settled.

A bare Region records ownership truth. It does not itself know how to interrupt a task, flush a stream or close a host handle. Those behaviours are supplied by settlement protocols and scope policy.

## Authority and borrowing

A scope can prove authority for an owned or borrowed item:

```lua
fibers.perform(scope:authorise_op(item, 'read'))
```

Borrowing grants rights without transferring custody:

```lua
local borrow = fibers.perform(
  cinematic:borrow_op(camera_handle, photo_mode, { 'preview' }, {
    name = 'photo-mode-camera-preview',
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

A claim is a fresh capability object tied to one Region, one root and its complete ordered owned subtree.

Claim creation:

```text
verify live root
compute subtree closure in pre-order
verify every member is live
create fresh claim capability
freeze the claimed topology
mark every member claimed
```

Only the original capability object can resolve the claim. Reconstructing its diagnostic fields does not confer authority.

While claimed, the subtree cannot be moved, released or claimed again.

Resolution kinds are:

```text
discharge   remove custody after complete successful settlement
fail        retain custody and settlement progress in failed phase
restore     return a pristine, unstarted claim to live custody
```

Restoration is not rollback of external cleanup. After any request, force or settlement step has begun, generic restoration is forbidden.

## Settlement protocol

Settlement starts only after the claim commits:

```text
transaction: claim and freeze subtree
post-commit: request quiescence from roots towards leaves
post-commit: settle from leaves towards roots
transaction: discharge the complete claim
```

Settlement may perform further options and may wait. It is not speculative cleanup inside a state transition.

A protocol is an explicit table:

```lua
local Settlement = require('fibers.region.settlement')

local camera_protocol = Settlement.protocol({
  name = 'camera-control',

  request_op = function(ctx, record, claim)
    -- Initiate quiescence. This step must not wait for descendants to settle.
    return record.item:request_release_op(claim.reason)
  end,

  settle_op = function(ctx, record, claim)
    -- Complete or observe final settlement after every child has settled.
    return record.item:released_op()
  end,

  force_op = function(ctx, record, claim)
    -- Optional policy-driven destructive escalation.
    return record.item:force_release_op(claim.reason)
  end,

  settle_result = Settlement.require_ok('camera settlement failed'),
})

local owned = Region.Owned.item(camera_handle, camera_protocol, {
  role = 'camera-control',
  settle_name = 'camera-control',
})

fibers.perform(scope:admit_op(owned))
```

`request_op`, `settle_op` and `force_op` construct `Op` values. Merely constructing those options must not perform irreversible cleanup. Synchronous construction errors and errors raised by result validators become settlement failures.

`settle_op` is mandatory. `request_op` and `force_op` are optional. A missing request is treated as immediately requested. `Settlement.request_then_wait` constructs the common two-phase form without merging the phases.

Operations which conventionally return `nil, err` should supply a result validator such as `Settlement.require_ok(...)`; arbitrary return values are otherwise treated as successful completion of the step.

Use `Region.Owned.tree` for an item with explicit owned children and `Region.Owned.inert` when no settlement work is required.

## Ordered settlement

A claim records its subtree in pre-order. Normal settlement uses two structural passes:

```text
request pass       pre-order
                   parent before children
                   siblings in declaration order

settlement pass    reverse pre-order
                   children before parent
                   siblings in reverse declaration order

ledger discharge   complete subtree removed atomically
```

For:

```text
root
├── a
│   └── a1
└── b
```

the order is:

```text
request root
request a
request a1
request b
settle b
settle a1
settle a
settle root
```

The request pass stops admission, propagates cancellation or initiates shutdown before descendants are joined. The settlement pass keeps parent infrastructure available until its descendants have finished.

A `request_op` may wait for acknowledgement that shutdown was accepted, but must not wait for descendant settlement. Such waiting belongs in `settle_op`.

A record is eligible for settlement only after all its direct children have settled. A failure in one branch does not prevent request or settlement attempts in an independent sibling branch. An ancestor remains unresolved while any descendant remains unresolved.

Independent roots have no cross-root transaction. Scope policy retires them sequentially in reverse admission order. A root moved into another Region receives a new admission position there; the order within its subtree is preserved.

### Aggregate protocols

One external obligation should have one principal settlement protocol. A parent may settle a facility as an aggregate, in which case structural child records should normally be inert. Parent and child protocols must not both perform the same irreversible close unless that operation is explicitly idempotent.

### Force escalation

Force is policy-driven rather than an automatic consequence of cancellation:

```text
force unresolved records in pre-order
then repeat settlement in reverse pre-order
```

Top-down force permits a parent process, transport or worker to be destroyed when that is required to unblock descendants. Bottom-up settlement still records what actually ended.

## Failed settlement remains custody truth

A settlement failure occurs after the claim has committed. It cannot be rolled back as though the claim never existed.

The claim retains a progress entry for each record. Public progress states include:

```text
not_requested
requested
forced
settled
request_failed
force_failed
settlement_failed
blocked_by_descendant
```

Already-settled records remain accounted as settled within the failed claim. They do not become live again and are not repeated by a retry.

A failing settlement protocol produces a `Settlement.Failure` value. Direct settlement raises it; checked scope boundaries retain it in their result and report. It is both a structured error and the exclusive recovery capability for the unresolved claim:

```lua
local Settlement = require('fibers.region.settlement')

local result = fibers.try_scope(function(scope)
  -- admit work whose settlement may fail
end)

local failure = result.settlement_failure
if failure and Settlement.is_failure(failure) then
  print(failure.item, failure.error)

  -- Resume ordinary settlement from retained progress.
  fibers.perform(failure:retry_op())

  -- Or, where policy permits destructive escalation:
  -- fibers.perform(failure:force_op())
end
```

A failure exposes `item`, `region`, `claim`, `claim_id`, `purpose`, `reason`, `records`, `progress`, `failures` and the first `error`. It provides `retry_op` and `force_op`. It does not provide restoration or arbitrary discharge authority.

Central rule:

> Failed settlement is an unresolved owned obligation with retained irreversible progress, not an exception erased during unwinding.

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
  fibers.spawn(function() error('boss controller failed') end)
  fibers.perform(encounter_finished_op())
end)
```

A supervisor isolates child failure according to its mode:

```lua
fibers.scope({
  policy = policy.supervisor({ child_failure = 'collect' }),
}, function()
  fibers.spawn(run_optional_fireworks)
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
  A pristine claim may be restored or manually discharged. A started settlement claim is discharged only after complete settlement, or retained as failed.

Ordered quiescence
  Settlement requests run parent-first; settlement completion runs child-first.

Progress retention
  Successful irreversible progress remains represented after a later failure and is skipped by retry.

Failure retention
  Failed settlement remains represented in the ledger with exclusive recovery authority.

Borrow separation
  Borrowing changes authority, not custody.

Boundary accounting
  A scope does not complete while its policy retains unaccounted live roots.

Policy causality
  Cancellation induced by a failure does not replace the failure which caused it.
```

## Facilities above the lifetime layer

Task, Flow, Stream, Pool and host-backed handles define facility-specific settlement protocols but use the same Region and Scope mechanisms. Future lifetime abstractions should be derived from custody, authority, claims and policy rather than creating unrelated cleanup systems.
