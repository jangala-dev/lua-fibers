# Lifetimes, regions and tasks

This document records the lifetime part of the public base kit.  The design is
centred on two nouns:

```text
Region  lifetime and ownership boundary
Task    owned running computation
```

There is no separate public extent/obligation/completion/cancellation layer.
Those ideas are represented by `Region`, `Task`, `Cell` and `Effect`.

## Regions, not policy scopes

A `Region` is mechanism.  It owns handles, can admit and release them, can
transfer them to another region, and can be closed.  It does not decide nursery
or supervisor policy.

```lua
local region = fibers.Region.new('main')
```

Expected policy layers include:

```text
nursery
  close on exit
  cancel children on failure
  join all admitted tasks

supervisor
  collect child results
  choose restart/cancel policy
  keep policy separate from ownership
```

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
local task = fibers.perform(region:spawn_op(function()
  return 7
end, 'child'))

local status, value = fibers.perform(task:join_op())
```

## Completion and cancellation

Completion and cancellation are not separate public mechanisms.  A task exposes
operations over its cells:

```lua
task:join_op()
task:peek_op()
task:cancel_op(reason)
task:cancelled_op()
task:check_cancelled_op()
```

Library authors who need different completion or cancellation shapes should use
ordinary `Cell` values.

## Ownership transfer

Ownership transfer is a transaction operation on regions:

```lua
from:transfer_op(handle, to)
```

The transferred handle can be a task today, and later a stream, process,
subscription, lease, or other owned object.  The important invariant is that
ownership changes are committed with the rest of the selected world.

## Spawn as effect

Starting work is a typed `Effect`, not speculative user code.  The public
`region:spawn_op(fn, name)` operation exercises this shape.  Future
nursery/supervisor APIs should be built above it rather than replacing it.
