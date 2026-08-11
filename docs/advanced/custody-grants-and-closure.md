# Custody, Grants and Closure

This document gives the complete advanced account of responsibility, authority and structural completion. For ordinary task and scope programming, begin with [Lifetimes](../guide/lifetimes.md).

Fibers has two fundamental semantic concepts:

```text
Op
  a possible committed world

Lifetime
  a continuing consequence of that world
```

Every continuing consequence is represented by one Lifetime node. Tasks, Scopes
and domain resources are restricted views of those nodes rather than separate
custody systems.

The advanced Lifetime model has three laws:

```text
Custody
  one tree of responsibility

Grant
  a graph of non-custodial authority

Closure
  how responsibility is resolved
```

Admission, movement, granting and closure all produce `Op` values. They therefore
compose with the same `choice`, `and_then`, `or_else`, `each` and `together` algebra
as messages, timers and resource transitions.

## 1. Lifetime views

A Lifetime may have several views:

```text
Scope
  authority to admit and manage child Lifetimes

Task
  execution and control view of a running Lifetime

Process, Stream, File, Listener, ...
  domain-specific views
```

The views refer to the same node. They do not each maintain cancellation,
parentage or closure state.

```lua
local task = fibers.perform(scope:spawn_op(function(child)
  -- `task` and `child` are views of one Lifetime.
  return 42
end))

local value = fibers.perform(task:await_op())
```

`Task:await_op()` waits for the complete Lifetime outcome. The body result is
available separately through `Task:body_result_op()` for advanced diagnostics.
A body can return successfully while Closure later fails, or fail while all
retained consequences close correctly.

## 2. Dormant construction and admission

An ownable value is constructed with a dormant Lifetime:

```lua
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')

local sensor = { name = 'sensor' }

Lifetime.define(sensor, {
  closure = Closure.protocol({
    label = 'sensor',

    request_op = function(_scope, entry, close)
      return entry.item:request_close_op(close.reason)
    end,

    finish_op = function(_scope, entry, _close)
      return entry.item:closed_op()
    end,

    force_op = function(_scope, entry, close)
      return entry.item:force_close_op(close.reason)
    end,
  }),
})
```

A definition is one-shot. The Closure protocol and propagation policy are
captured at definition time. Later mutation of the source Lua table does not
change the admitted Lifetime. This defines when runtime configuration takes
effect; it is not a general promise that Lua values are immutable.

Structural children must already carry explicit Lifetimes:

```lua
Lifetime.define(parent, {
  closure = parent_closure,
  children = { child_a, child_b },
})
```

Admission attaches the dormant subtree to a Scope:

```lua
fibers.perform(scope:admit_op(sensor))
```

If admission loses a `choice`, the Lifetime remains dormant and no running body
starts. A running body starts only after admission commits.

## 3. Custody

Every live Lifetime has exactly one custodial parent. The parent is accountable
for eventually closing the child or moving it elsewhere.

A Scope is the custody capability of its Lifetime:

```lua
scope:admit_op(resource)
scope:move_op(resource, target_scope)
scope:offer_op(resource, target_scope, terms)
scope:accept_op(filter)
scope:close_op(resource, reason)

scope:has_custody_op(resource)
```

The focused predicate is the only public custody observation. Fibers does not expose generic children, subtree or custodian snapshots; topology is changed through custody operations rather than mirrored as an observational API.

### Atomic movement

Movement changes the custodial parent of a complete subtree in one committed
world:

```lua
fibers.perform(source:move_op(stream, destination))
```

There is no interval in which both Scopes, or neither Scope, are responsible.
The subtree retains its internal parentage.

### Negotiated movement

When both sides must participate, use offer and acceptance:

```lua
local moved = fibers.perform(Op.together({
  source:offer_op(stream, destination, { purpose = 'request-body' }),
  destination:accept_op(function(offer)
    return offer.item == stream
  end),
}))
```

The offer and movement are one transaction. Rejected alternatives do not consume
an unrelated offer or partially move custody.

### Custody is not a general reference

Holding a Lua reference does not imply custody. It also need not imply authority
to use the resource. Custody is the unique responsibility relation stored in the
Runtime-local Lifetime forest.

## 4. Grants

A Grant is a Lifetime carrying selected authority over another Lifetime. It does
not change custody.

```lua
local grant = fibers.perform(source:grant_op(
  stream,
  worker,
  { 'read' }
))
```

The Grant becomes a child of `worker`. The Stream remains a child of `source`.
The worker can prove the granted right:

```lua
local stream, authority = fibers.perform(worker:can_op(stream, 'read'))
```

Closing the Grant revokes the authority:

```lua
fibers.perform(worker:close_op(grant, 'revoked'))
```

A Grant closes automatically when its holding Scope closes.

### Rights

Rights may be supplied as a string, a dense array, or a string-keyed set:

```lua
source:grant_op(resource, worker, 'read')
source:grant_op(resource, worker, { 'read', 'observe' })
source:grant_op(resource, worker, { read = true, observe = true })
```

Sparse arrays, duplicate rights and mixed array/map forms are rejected. Rights,
the subject and transfer terms are copied privately when the Grant is
constructed. Mutating the returned Lua table or an `inspect()` result cannot add
authority or make a Grant transferable.

Only the subject's current custodian may issue a Grant. Granted authority may
be exercised by the holder and its custodial descendants, but it cannot be
copied onwards by issuing a sub-Grant. This keeps revocation direct and avoids
implicit authority lineage. A future version may add explicit delegation terms,
but delegation is not part of the version 1 contract.

### Terms

Grants are non-transferable by default:

```lua
local grant = fibers.perform(source:grant_op(resource, worker, { 'read' }, {
  terms = { transferable = true },
}))
```

Version 1 recognises only the `transferable` term. Unknown terms are rejected
rather than silently retained. Deadline, use-count, delegation, exclusivity and
compatibility must be represented explicitly by the subject facility or another
transactional resource until the Grant contract is deliberately extended.

### Subject closure

A Grant is effective only while both the Grant and its subject are live. Closing
the subject invalidates every Grant over it immediately, even if a holder has not
yet closed the Grant node itself. Authority is available to the holding Scope and
its descendants; it does not flow upwards to ancestors or sideways to siblings.

### Custody and Grants are deliberately distinct

Custody is unique and tree-shaped because it determines Closure responsibility.
Grants are non-unique and graph-shaped because several Lifetimes may hold
compatible authority over one subject.

Trying to represent custody as merely another Grant would lose the invariant
that exactly one parent is responsible for Closure.

## 5. Closure

Closure is the only public termination contract. It includes:

- local shutdown of the node;
- propagation from body, cancellation and child outcomes;
- ordered closure of descendants;
- retry and force after incomplete closure.

A Lifetime has one monotonic Closure phase:

```text
dormant
  ↓
open
  ↓
close_requested
  ↓
closing
  ├──→ closed
  └──→ closure_failed
          ├── retry
          └── force
```

Natural body completion, explicit cancellation and custodian-driven shutdown all
converge on this state machine.

### Local Closure protocol

A local protocol has two ordinary phases and one optional escalation phase:

```lua
Closure.protocol({
  name = 'resource',

  request_op = function(scope, entry, close)
    -- Initiate quiescence. Do not wait for descendants here.
    return entry.item:request_close_op(close.reason)
  end,

  finish_op = function(scope, entry, close)
    -- Complete or observe local closure after descendants finish.
    return entry.item:closed_op()
  end,

  force_op = function(scope, entry, close)
    -- Optional destructive escalation.
    return entry.item:force_close_op(close.reason)
  end,
})
```

Callbacks receive a bounded Closure context containing the root, reason,
purpose and current phase. They never receive the engine's exclusive internal
close token.

The common two-phase form is:

```lua
Closure.request_then_wait(request_fn, finished_fn, {
  name = 'resource',
  force_op = force_fn,
  finish_result = Closure.require_ok('resource closure failed'),
})
```

A passive value may use only `finish_op`. A running Lifetime normally uses the
standard running Closure, which requests cancellation during abnormal shutdown
and waits for the complete body outcome.

### Structural order

For an ordered tree:

```text
root
├── a
│   └── a1
└── b
```

Closure runs:

```text
request root
request a
request a1
request b

finish b
finish a1
finish a
finish root
```

Requests travel from parents to children so that admission can stop and
shutdown can propagate. Finishing travels from children to parents so that
parent infrastructure remains available while descendants quiesce.

Siblings request in declaration order and finish in reverse declaration order.
Independent roots close in reverse admission order.

### Propagation

Child failure behaviour is part of Closure rather than a separate policy system.
The built-in forms are:

```lua
Closure.nursery()
Closure.supervisor({ child_failure = 'fail_at_exit' })
Closure.supervisor({ child_failure = 'collect' })
Closure.supervisor({ child_failure = 'ignore' })
```

A nursery propagates a failed child to the boundary and requests closure of the
remaining work. A supervisor records child outcomes according to its configured
mode without necessarily closing siblings.

Custom propagation is pure:

```lua
local propagation = {
  on_child_outcome = function(_self, parent, state, child, outcome)
    if outcome.tag == 'failed' then
      return {
        fail_boundary = true,
        seal = true,
        cancel_body = true,
        cancel_children = true,
      }
    end
    return {}
  end,
}

local closure = Closure.running(propagation)
```

Domain-local shutdown and propagation compose without either replacing the
other:

```lua
local closure = Closure.combine(local_resource_closure, propagation)
```

Children inherit only the propagation projection. They never inherit their
parent's local `request_op`, `finish_op` or `force_op`.

## 6. Closure failure and recovery

External closure is not transactional. Some descendants may finish before a
later descendant fails. Fibers therefore retains irreversible progress rather
than pretending the subtree became live again.

Checked boundaries expose a `Closure.Failure`:

```lua
local result = fibers.try_scope(function(scope)
  -- Work whose Closure may fail.
end)

local failure = result.closure_failure
if failure then
  local report = failure:inspect()

  -- Continue ordinary Closure from retained progress.
  failure:retry()

  -- Or apply the optional force phase.
  -- failure:force()
end
```

The failure contains diagnostics and one opaque recovery capability. It does not
expose the engine's close token, generic restoration or arbitrary discharge.
Retry or force consumes that capability only when its operation commits. A
failed recovery issues one new failure capability; a successful recovery cannot
be repeated. Completed descendants are skipped during retry.

A failed Closure remains custody truth: the parent is still accountable for the
unresolved consequence until retry or force reaches `closed`.

## 7. Body result, domain result and Lifetime outcome

These facts remain distinct:

```text
body result
  what the running function returned or raised

domain result
  what the resource means, for example process exit or connection failure

Lifetime outcome
  whether all continuing consequences closed correctly
```

A Process may exit before its Streams and host handles close. A Dial may report a
domain connection failure while its Lifetime closes successfully. A successful
body does not erase a later Closure failure.

The distinction is necessary for truthful accounting rather than additional
ontology.

## 8. Host acquisition

An irreversible host call may return a handle before the next transactional
admission can run. During that setup interval Fibers keeps lexical ownership of
the raw value. It is not a Lifetime and is never exposed to application code.

The observable law is simply:

> A returned host value is owned continuously: setup either adopts it into the
> normal Lifetime graph or closes it before the setup extent exits.

## 9. Core laws

### Unique custody

Every live Lifetime has exactly one custodial parent.

### Atomic admission

A losing admission starts no body and creates no custody.

### Atomic movement

A complete subtree changes parent in one committed world.

### Delegated authority

Only the current custodian of a subject may issue a Grant over it.

### Grant revocation

Closing a Grant revokes its authority; closing the subject invalidates all
Grants over it.

### Monotonic Closure

A Lifetime moves forwards through its Closure phases. Failed Closure retains
progress and responsibility.

### Ordered Closure

Requests run parent-first; finishing runs child-first.

### Complete containment

A Lifetime cannot reach `closed` while it retains unresolved descendants.

### Runtime locality

A live Lifetime belongs to one Runtime-local forest and cannot cross Runtime
stores.

## 10. Summary

The advanced model can be stated in four sentences:

> Every continuing consequence is a Lifetime.
> Each Lifetime has exactly one custodian.
> Other Lifetimes may hold Grants over it.
> Closure resolves it and everything for which it remains responsible.

Every change to custody, Grants or Closure is an `Op`, so the Lifetime model
uses the existing possible-world algebra rather than introducing a second one.
