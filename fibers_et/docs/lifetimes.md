# Transactional lifetime management
## Lifetime is the compound facility

`Region` is the ledger primitive. It records ownership and admission. `Lifetime` is the compound facility for practical transactional lifetime management. It builds on Region, Task, Source and Effect while keeping policy out of the primitive ledger.

```lua
local life = fibers.Lifetime.new('request')
local task = fibers.perform(life:spawn_op(function() return 'ok' end))
fibers.perform(life:transfer_op(task, supervisor_life))
```

Policies such as nursery, supervisor and compatibility scope should use `Lifetime` internally. Advanced code can still use `Region` directly when it needs the sparse ledger.

This document records the lifetime part of the public base kit.  The design is
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

The core region operations are deliberately small:

```lua
region:admit_op(item)
region:transfer_op(item, target_region)
region:seal_op(reason)
region:settle_op(item)
region:owns_op(item)
region:status_op()
```

`seal_op` stops new admission.  It does not cancel, join, settle, or transfer
anything by itself.  Policy layers may later provide richer shutdown operations,
but a bare Region only seals admission.

`settle_op` removes ownership of an item that is settle-ready.  For generic
handles this is immediate.  For a `Task`, settlement is allowed after completion.

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

local status, value = fibers.perform(task:join_op())
```

Task spawning is exposed ergonomically by `Lifetime:spawn_op`. The lower-level `Task.spawn_op(region, ...)` remains available: Region owns; Task
spawns.

## Completion and cancellation

Completion and cancellation are represented by ordinary task operations over
Cells:

```lua
task:join_op()
task:peek_op()
life:cancel_op(task, reason)  -- owner-authority request
task:cancelled_op()
task:check_cancelled_op()
```

For policy code that wants owner authority to be explicit, cancellation may be
requested through the owning Lifetime:

```lua
life:cancel_op(task, reason)
```

This succeeds only if the Lifetime's underlying Region owns the task in the selected world. The lower-level Region form remains available for implementers.

## Negotiated handoff

A Lifetime can also transfer ownership through a rendezvous with the receiving Lifetime:

```lua
fibers.perform(fibers.tensor({
  from:offer_op(task, to),
  to:accept_op(),
}))
```

The offer contributes both the ownership transfer and a handoff rendezvous. The accept operation is the receiver's matching rendezvous. The transfer commits only if both sides participate in the same committed world.

## Ownership transfer

Ownership transfer is one transaction operation:

```lua
from:transfer_op(handle, to)
```

The transfer is not exposed as release followed by admission.  If it commits,
the ownership ledger publishes a single `transferred` lifetime effect.  If it
loses, ownership is unchanged and no transfer effect is emitted.

This is the operation that makes structured concurrency only one lifetime policy:
work may be transactionally adopted, detached, promoted, or handed off between
regions without becoming ownerless.

## Lifetime effects

Ownership transitions derive standard typed effects:

```text
admitted
transferred
settled
```

These effects are transaction consequences.  They are published after ownership
journals commit and before selected participants resume.  They are not returned
to a participant as work to do later.

## Policy layers

Expected policies include:

```text
nursery
  spawn children into a Lifetime
  on failure, request cancellation
  on exit, seal, join, settle

supervisor
  own tasks for longer than one lexical block
  record failures without necessarily cancelling siblings
```

These policies should be built above Lifetime, Region, Task, Cell and Effect.  They should
not change the operation algebra.


## Launch policies

The runtime has no universal lifetime policy.  A launch boundary may install one:

```lua
fibers.launch(fibers.policy.nursery(), function(nursery)
  local task = fibers.spawn(function()
    -- policy-aware work
  end)
end)
```

Inside a nursery launch, `fibers.spawn` admits a `Task` to the nursery Lifetime and
`fibers.perform` is interruptible according to the nursery policy.  Outside such
a policy, raw unstructured fibres are explicit: use `spawn_raw` or the low-level
`Runtime` API.