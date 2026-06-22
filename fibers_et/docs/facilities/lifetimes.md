# Transactional lifetime management
## Lifetime is the compound facility

`Region` is the ownership primitive. It records ownership and admission. `Lifetime` is the compound facility for practical transactional lifetime management. It builds on Region, Task, Source and Effect while keeping policy out of the primitive ownership boundary.

```lua
local life = fibers.Lifetime.new('request')
local task = fibers.perform(life:spawn_op(function() return 'ok' end))
fibers.perform(life:handoff_op(task, supervisor_life))
```

Policies such as nursery and supervisor should use `Lifetime` internally. Advanced code can still use `Region` directly when it needs the sparse ownership boundary.

This document records the lifetime facility built over the public base kit.  The design is
centred on transactional ownership, not on tree-shaped scopes.

```text
Region  ownership and admission boundary
Task    standard owned running computation
Effect  committed lifetime transition or runtime obligation
```

Structured concurrency is a policy over these mechanisms.  It is not the
mechanism itself.

## Regions are generic

A `Region` owns handles.  A handle might be a task, stream pump, process,
subscription, lease, host resource, or any other owned obligation.

```lua
local region = fibers.Region.new('request')
local lease = fibers.Region.handle('lease', { kind = 'lease' })

fibers.perform(region:admit_op(lease))
```

The core region options are deliberately small:

```lua
region:admit_op(item)
region:reassign_op(item, target_region)
region:seal_op()
region:release_op(item)
region:owns_op(item)
region:members_op()
region:snapshot_op()
```

`seal_op` stops new admission.  It does not cancel, settle owned items, mark the Lifetime settled, or reassign
anything by itself.  Policy layers may later provide richer shutdown options,
but a bare Region only seals admission.

`release_op` removes ownership of a live root item.  It is a sparse ledger command: it
does not prove that a task, stream, lease, or process has completed.  Compounds such as
`Lifetime:settle_item_op()` first claim the owned subtree, run its settlement
protocols, and then release it with the claim authority.

The higher-level `Lifetime:settle_op()` is different: it is a terminal transition
for the lifetime facility itself.  It succeeds only when the underlying Region is
closed and empty, and discharges a committed `settled` lifetime event.

## Tasks

A `Task` is the standard owned computation abstraction.  It is built from the
base kit:

```text
Region  admits and owns the task
Cell    records completion state
Cell    records cancellation request state
Effect  starts the task after admission commits
```

A task spawn is transactional:

```text
admit task to region
emit spawn effect
commit
runtime starts the task after commit
```

If the admitting transaction loses, the task is not started.

```lua
local life = fibers.Lifetime.new('request')
local task = fibers.perform(life:spawn_op(function()
  return 7
end, { name = 'child' }))

local value = fibers.perform(task:await_op())
```

Task spawning is exposed ergonomically by `Lifetime:spawn_op`. The lower-level `Task.spawn_op(region, ...)` remains available: Region owns; Task
spawns.

## Completion and cancellation

Completion and cancellation are represented by ordinary task options over
Cells:

```lua
task:await_op()     -- unwraps the task Exit, preserving Lua multiple returns
task:exit_op()     -- returns the terminal Exit value for policy code
life:request_cancel_op(task, reason)  -- owner-authority request
task:request_cancel_op(reason)       -- lower-level task request
task:cancel_requested_op()
task:state_op()
```

For policy code that wants owner authority to be explicit, cancellation may be
requested through the owning Lifetime:

```lua
life:request_cancel_op(task, reason)
```

This succeeds only if the Lifetime's underlying Region owns the task in the selected world. The lower-level Task form remains available for implementers as `task:request_cancel_op(reason)`.

## Negotiated handoff

A Lifetime can also hand off ownership through a rendezvous with the receiving Lifetime:

```lua
fibers.perform(fibers.tensor({
  from:offer_handoff_op(task, to),
  to:accept_handoff_op(),
}))
```

The offer contributes both the ownership handoff and an ordinary channel rendezvous carrying an offer value. The accept option receives the offer and uses and_then to accept only values matching its criteria, before commit. The handoff commits only if both sides participate in the same committed world.

## Ownership handoff

Ownership handoff is one transactional option:

```lua
from:handoff_op(handle, to)
```

The handoff is not exposed as release followed by admission.  If it commits,
the lifetime discharges handoff effects and the underlying ownership record moves
in the same committed world.  If it loses, ownership is unchanged and no handoff
effect is emitted.

This is the option that makes structured concurrency only one lifetime policy:
work may be transactionally adopted, detached, promoted, or handed off between
regions without becoming ownerless.

## Lifetime effects

Lifetime transitions discharge standard typed effects with a stable event shape:

```text
admitted
reassigned
handed_off
handoff_received
cancel_requested
settled_item
settlement_failed
closed
settled
```

Events carry ordinary fields such as `type`, `lifetime`, `lifetime_id`, `region`,
`item`, `item_id`, `item_kind`, `from`, `from_id`, `to`, `to_id`, `reason` and
`report` when applicable. These effects are transaction effects.  They are
discharged after ownership journals commit and before selected participants
resume. They are not returned to a participant as work to do later.

`settlement_failed` is discharged when a settlement protocol fails after its claim
has committed.  The item remains owned and its Region record exposes
`phase = "settlement_failed"` until policy code decides what to do next.

`Lifetime:next_event_op()` observes committed events through the Lifetime's event
Source.

## Policy layers

Expected policies include:

```text
nursery
  spawn children into a Lifetime
  on failure, request cancellation
  on exit, close, await tasks, settle owned items, settle the Lifetime

supervisor
  own tasks for longer than one lexical block
  record failures without necessarily cancelling siblings
```

These policies should be built above Lifetime, Region, Task, Cell and Effect.  They should
not change the option algebra.

For the exact claim and settlement laws, see `docs/facilities/settlement.md`.


## Launch policies

The runtime has no universal lifetime policy.  A launch boundary may install one:

```lua
fibers.launch(fibers.facility.policy.nursery(), function(nursery)
  local task = fibers.spawn(function()
    -- policy-aware work
  end)
end)
```

Inside a nursery launch, `fibers.spawn` admits a `Task` to the nursery Lifetime and
`fibers.perform` is interruptible according to the nursery policy.  Outside such
a policy, raw unstructured fibres are explicit: use `spawn_raw` or the low-level
`Runtime` API.