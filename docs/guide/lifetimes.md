# Lifetimes

This guide is the complete practical account of tasks, scopes, cancellation,
custody, Grants and Closure.

The central idea is:

> Options describe possible actions. Lifetimes account for the continuing
> consequences left by actions which commit.

Lifetime operations are themselves Options. Admission, movement, authority,
cancellation and completion can therefore participate in the same transaction
as communication and managed state.

For exact signatures, see the [API reference](../api-reference.md). For the full
Closure protocol and authority model, see
[Custody, Grants and Closure](../advanced/custody-grants-and-closure.md).

## 1. One Lifetime, several views

A Lifetime is the underlying continuing consequence. Tasks, Scopes and domain
resources expose different views of it.

```text
Lifetime
├── Scope view: child admission, custody and boundary policy
├── Task view: execution, cancellation and completion
└── domain view: Stream, Process, File, Listener, application resource, ...
```

A structured Task illustrates the relationship:

```lua
local task = scope:spawn(function(child_scope)
  return run_service(child_scope)
end)
```

The caller receives a `Task`. The running body receives a `Scope`. They are two
capabilities over the same Lifetime, not two linked lifecycle records.

A Scope contains no independent custody tree or cancellation state. A Task
adds only execution-specific state, including its body-result Completion; its
custody, close intent and terminal outcome belong to the same underlying
Lifetime.

This lets one system account for:

- child tasks;
- nested scopes;
- Streams and Files;
- Processes and sockets;
- application-defined resources;
- Grants of temporary authority.

## 2. The Lifetime law

A continuing consequence moves through a simple responsibility structure:

```text
dormant
   │ admit
   ▼
live under exactly one custodian
   │
   ├── move ──► live under another custodian
   │
   └── request close
           ▼
        closing
           │ responsibility discharged
           ▼
        retired
```

The practical laws are:

1. A dormant Lifetime has not entered Runtime responsibility.
2. Admission makes a dormant construction tree real as an actual custody tree:
   its root is admitted under the chosen custodian and each descendant remains
   owned by its parent.
3. Every live or closing Lifetime has exactly one custodial parent, except the
   Runtime root.
4. Movement changes one Lifetime's custodial parent atomically; its descendants
   remain beneath it.
5. Grants add authority without changing custody.
6. A close request moves a live Lifetime to `closing`; retirement occurs only
   after its local consequence and every descendant have been discharged.
7. A Closure fault is retained while the Lifetime remains `closing`; failure
   never manufactures retirement.

Holding a Lua reference does not create custody or extend a Lifetime.

## 3. Root and nested scopes

```lua
fibers.run(function(scope)
  -- program body
end)
```

`fibers.run` creates a Runtime and root Scope, drives the program, accounts for
retained custody, then closes the Runtime.

The raising form returns body values or raises a structured failure:

```lua
local value = fibers.run(function()
  return 42
end)
```

The checked form returns a `ScopeResult`:

```lua
local result = fibers.try_run(function()
  return 42
end)

if result.ok then
  print(result:unpack())
else
  print(result:tostring())
end
```

A nested scope creates another responsibility boundary:

```lua
local value = fibers.scope(function(scope)
  scope:spawn(run_reader)
  scope:spawn(run_writer)
  return wait_for_result()
end)
```

The checked form is `fibers.try_scope`.

Use a nested scope when a group of tasks or resources should:

- share one lifetime boundary;
- close together;
- apply one child-failure policy;
- move as one custody subtree;
- produce one boundary report.

Returning a Lua reference from a nested scope does not move custody. A resource
which must survive the scope must be moved explicitly before the boundary
closes.

## 4. Tasks: execution and complete outcome

```lua
local task = scope:spawn(function()
  return do_work()
end)
```

A Task is continuing work admitted to a Scope.

The important Options are:

```lua
task:body_result_op()
task:outcome_op()
task:request_cancel_op(reason)
task:cancel_requested_op()
```

`request_cancel` is the exact direct twin of `request_cancel_op`. `await()` is a causal convenience over the complete outcome and has no `_op` twin.

### Body result

`body_result_op()` answers:

> How did the executing function finish?

It yields a `Task.Exit` tagged as:

```text
returned
failed
cancelled
```

```lua
local exit = fibers.perform(task:body_result_op())

if exit.tag == 'failed' then
  report_failure(exit.error)
end
```

The body can finish while resources or descendants retained by the Task are
still closing.

### Complete outcome

`outcome_op()` answers:

> Has the complete Task Lifetime, including descendants and Closure, resolved?

```lua
local outcome = fibers.perform(task:outcome_op())
```

It yields the structured outcome rather than raising. Use it when the outcome
must participate in another Option expression.

### Awaiting

```lua
local value = task:await()
```

`await` waits for the complete outcome and raises structured failure where
appropriate. It is deliberately a participant-level causal convenience rather
than an Option.

Use:

- `body_result_op` for prompt execution observation;
- `outcome_op` for transactional inspection of complete resolution;
- `await` for ordinary post-commit continuation which should raise failure.

Because `outcome_op` remains an ordinary Option, `map`, `and_then`, `choice` and
the other algebraic combinators may be applied to the complete structured
outcome before commitment.

## 5. Transactional task admission

`scope:spawn_op(fn)` does more than create an asynchronous computation. It
constructs a dormant Task Lifetime, admits it transactionally, and starts the
body only after the admitting world commits.

```text
construct dormant Task
        ↓
transactionally admit its Lifetime
        ↓
commit admission
        ↓
activate the Task body
```

A losing `spawn_op` branch:

- does not start the body;
- does not bind the Lifetime into the Runtime custody tree;
- creates no responsibility which later needs cancellation.

### Receive work and admit its handler

```lua
local Op = require('fibers.op')

local accept_request = requests:get_op():and_then(
  Op.guard(function(request)
    return scope:spawn_op(function()
      return handle_request(request)
    end)
  end)
)
```

If admission cannot commit, the request is not consumed and no handler starts.

### Reserve capacity and admit work

```lua
local admitted = worker_capacity:take_op(1)
  :and_then(scope:spawn_op(run_worker))
```

Capacity and responsibility are created together.

### Admit a complete task group

```lua
local rows = fibers.perform(Op.each({
  scope:spawn_op(run_reader),
  scope:spawn_op(run_writer),
  scope:spawn_op(run_monitor),
}))

local reader = rows[1][1]
local writer = rows[2][1]
local monitor = rows[3][1]
```

All three Tasks are admitted or none is. `each` returns one nil-preserving result
row per lane; see [Options](options.md#each-independent-support).

### Admission fallback

```lua
local task, reason = fibers.perform(
  scope:spawn_op(run_request)
    :or_else(Op.always(nil, 'scope not accepting now'))
)
```

The fallback means the complete admission action cannot happen now, not merely
that one local flag was false.

## 6. Body completion and replacement policy

The distinction between body completion and complete Lifetime outcome lets a
supervisor state its replacement policy precisely.

### React promptly to body failure

```lua
local exit = fibers.perform(service:body_result_op())
```

This observes the service function as soon as it finishes, even if retained
resources are still closing.

### Replace only after complete retirement

```lua
local replacement = service:outcome_op()
  :and_then(scope:spawn_op(run_replacement))
```

The replacement cannot start until the old Lifetime has fully resolved.

### Replace after body exit

```lua
local replacement = service:body_result_op()
  :and_then(scope:spawn_op(run_replacement))
```

This may overlap with the old Lifetime's remaining Closure work. That can be
correct for some systems and unsafe for others. Fibers makes the choice explicit.

### Select among service events

```lua
local kind, value = fibers.perform(Op.choice(
  service:body_result_op():map(function(exit)
    return 'body-finished', exit
  end),
  service:outcome_op():map(function(outcome)
    return 'fully-closed', outcome
  end),
  shutdown:get_op():map(function(reason)
    return 'shutdown', reason
  end)
))
```

Long-lived coordinators can select over body exits, complete outcomes,
cancellation, timers and application messages using one algebra.

## 7. Nursery and supervisor policies

Failure policy belongs to the Scope which owns the work.

### Nursery

The root scope follows nursery semantics.

When a nursery child fails, the boundary:

- records the failure;
- seals further admission where required;
- requests cancellation or Closure of remaining siblings;
- accounts for retained descendants;
- fails the boundary.

This is live fail-fast behaviour. The parent does not merely inspect child
results when it happens to finish.

### Supervisor

A supervisor applies an explicit alternative child-failure policy:

```lua
local Closure = require('fibers.closure')

local result = fibers.try_scope({
  closure = Closure.supervisor({
    child_failure = 'collect',
  }),
}, function(scope)
  scope:spawn(service_a)
  scope:spawn(service_b)
  return wait_for_shutdown()
end)
```

The supported policies include:

- `fail_at_exit`;
- `collect`;
- `ignore`.

A supervisor is not an unstructured escape hatch. Retained work remains under
custody and must reach Closure.

Custom Scope policies and local resource Closure protocols are covered in
[Custody, Grants and Closure](../advanced/custody-grants-and-closure.md).

## 8. Cancellation as a composable transition

Cancellation is a cooperative request represented within the Lifetime system.

```lua
local task = scope:spawn(run_worker)

local first, reason = fibers.perform(
  task:request_cancel_op('service stopping')
)
```

`request_cancel_op` coordinates:

1. a request for the Lifetime to close;
2. a managed cancellation-state transition;
3. a committed interrupt effect.

A losing cancellation branch leaves no committed cancellation request.

### Couple cancellation to state

```lua
local cancel_and_record = task:request_cancel_op('deadline')
  :and_then(status:write_op('cancelling'))
```

The status cannot claim cancellation unless the request commits.

### Deadline and accountable shutdown

```lua
local kind, value = fibers.perform(Op.choice(
  task:outcome_op():map(function(outcome)
    return 'completed', outcome
  end),
  Sleep.sleep_op(5)
    :and_then(task:request_cancel_op('deadline'))
    :map(function()
      return 'deadline'
    end)
))

if kind == 'deadline' then
  local outcome = fibers.perform(task:outcome_op())
  inspect_shutdown(outcome)
end
```

The deadline branch commits the cancellation request. Waiting for the outcome
then establishes whether the complete consequence actually closed.

### Observe cancellation

```lua
local requested, reason = fibers.perform(
  task:cancel_requested_op()
)
```

`cancel_requested_op` waits for a cancellation request. Fibers does not expose a generic current-cancellation snapshot; when a program needs the present alternative, compose `cancel_requested_op()` with `or_else`.

A non-blocking observation can use `or_else`:

```lua
local status, reason = fibers.perform(
  task:cancel_requested_op()
    :map(function(_, why)
      return 'requested', why
    end)
    :or_else(Op.always('not-requested'))
)
```

### Cooperative boundary

A fiber observes cancellation at a cooperating Fibers operation or another
recognised cancellation point.

Cancellation cannot pre-empt:

- an infinite CPU loop;
- a blocking foreign function;
- non-cooperative host code;
- application code which never reaches a suspension boundary.

Cancellation asks work to stop. Closure accounts for whether it did.

## 9. Cancellation masks and suspension-free regions

```lua
fibers.mask(function()
  finish_small_critical_bookkeeping()
end)
```

`mask` defers ordinary cancellation observation in a dynamic region. It does not
prevent suspension.

```lua
fibers.without_suspension(function()
  reduce_event(state, event)
end)
```

`without_suspension` requires the current fiber to retain execution until the
function returns. It does not mask cancellation which has already been observed,
and it does not make ordinary Lua state transactional.

Use:

- `mask` when cancellation observation must be deferred briefly;
- `without_suspension` when no scheduling hand-off may occur;
- both only when the corresponding contract is genuinely required.

## 10. Custody: transactional responsibility topology

Every live Lifetime has one custodial parent. Custody answers:

> Who is responsible for ensuring that this consequence eventually closes?

The principal Scope operations are:

```lua
scope:admit_op(value)
scope:move_op(value, target)
scope:offer_op(value, target, terms)
scope:accept_op(filter)
scope:start_retire_op(value, reason)
scope:retire(value, reason)
```

A focused transactional custody predicate is available when a protocol genuinely needs it:

```lua
scope:has_custody_op(value)
```

Fibers deliberately does not expose generic children, subtree or custody snapshots. Responsibility changes should normally be expressed by `admit_op`, `move_op`, `offer_op`, `accept_op`, `grant_op`, `can_op` and `start_retire_op`, rather than observed through a parallel topology API.

### Dormant resources

Application and facility authors may define a value with a dormant Lifetime.
Admission attaches the complete dormant subtree to a Scope:

```lua
local resource = make_resource()

fibers.perform(scope:admit_op(resource))
```

If admission loses a choice, the resource remains dormant.

The advanced construction API is described in
[Custody, Grants and Closure](../advanced/custody-grants-and-closure.md).

### Atomic movement

```lua
fibers.perform(source:move_op(stream, destination))
```

Movement atomically changes the parent Lifetime's custodian. Its descendants
remain owned beneath it, so responsibility for the complete custody subtree
follows that one transition. There is no visible interval in which both Scopes,
or neither Scope, are responsible for the moved root.

### Move responsibility with application state

```lua
local handoff = registry:write_op({
  owner = 'session-handler',
  stream = stream,
}):and_then(
  source:move_op(stream, session_handler)
)
```

The registry does not claim a transfer which failed to commit.

Where the acknowledgement should also be part of the same action:

```lua
local handoff = registry:write_op({
  owner = 'session-handler',
  stream = stream,
}):and_then(
  source:move_op(stream, session_handler)
):and_then(
  acknowledgements:put_op(stream)
)
```

### Move a resource bundle

```lua
fibers.perform(Op.each({
  source:move_op(reader, destination),
  source:move_op(writer, destination),
}))
```

Both independent resources move together.

If the resources are custody descendants of one parent Lifetime, moving the
parent changes only that parent's custodian; the descendants remain beneath it,
so the complete subtree moves as a consequence of the one `move_op`.

### Adopt a running task

A Task is a movable Lifetime. Responsibility for a live service can therefore
move to another supervisor without stopping the Task:

```lua
fibers.perform(bootstrap:move_op(service_task, supervisor))
```

The Task's child Scope is a view of the same Lifetime, so its descendants move
with it.

This supports:

- bootstrap ownership followed by permanent supervision;
- session adoption;
- service hand-off;
- responsibility-aware work stealing.

### Explicit scope escape

Returning a resource from a nested scope does not move custody:

```lua
local resource = fibers.scope(function(inner)
  return acquire_resource(inner)
end)
```

The resource remains under `inner` and is closed with that boundary.

To let it survive, move responsibility before returning:

```lua
local resource = fibers.scope(function(inner)
  local value = acquire_resource(inner)
  fibers.perform(inner:move_op(value, outer))
  return value
end)
```

## 11. Negotiated custody: offer and accept

`move_op` is unilateral: the current custodian names the target.

`offer_op` and `accept_op` make both sides participate.

```lua
local rows = fibers.perform(Op.together({
  source:offer_op(stream, destination, {
    purpose = 'request-body',
  }),
  destination:accept_op(function(offer)
    return offer.item == stream
  end),
}))

local offer = rows[1][1]
```

The offer, acceptance and custody movement are one transaction. A rejected
filter rejects that possible world; it does not consume an unrelated offer and
continue procedurally.

Use negotiated custody when the receiver must decide whether it can presently
take responsibility.

### Responsibility-aware work distribution

Several workers may wait with filtered `accept_op` values while a source offers
work. Alternatively, a source may choose among several target offers:

```lua
local accepted = fibers.perform(Op.choice(
  source:offer_op(session, worker_a),
  source:offer_op(session, worker_b),
  source:offer_op(session, worker_c)
))
```

The selected target receives custody as part of accepting the work. Work is not
merely delivered and left for a separate ownership registry to catch up.

### Reciprocal exchange

Two parties can exchange responsibility in one interacting product:

```lua
local exchange = Op.together({
  left:offer_op(left_item, right),
  right:accept_op(function(offer)
    return offer.item == left_item
  end),

  right:offer_op(right_item, left),
  left:accept_op(function(offer)
    return offer.item == right_item
  end),
})
```

The complete reciprocal hand-off commits or none of it does.

## 12. Grants: authority without responsibility transfer

Custody and authority answer different questions:

```text
Custody
  Who must eventually close it?

Grant
  Who may presently do what with it?
```

Issue a Grant with:

```lua
local grant = fibers.perform(owner:grant_op(
  stream,
  worker,
  { 'read' }
))
```

The Stream remains under `owner`. The Grant becomes a Lifetime under `worker`.
Closing the worker closes its Grant and revokes the authority without moving or
closing the Stream.

### Issue authority and deliver it atomically

```lua
local delegated = owner:grant_op(
  stream,
  worker,
  { 'read' }
):and_then(
  Op.guard(function(grant)
    return worker_inbox:put_op({
      stream = stream,
      grant = grant,
    })
  end)
)
```

The worker cannot receive the resource reference without the corresponding
Grant, and the Grant is not issued without delivery.

### Prove authority with `can_op`

```lua
local item, evidence = fibers.perform(
  worker:can_op(stream, 'read')
)
```

The evidence records whether authority came from:

- custody;
- a Grant;
- authorised Closure work.

When authority is absent, `can_op` is unavailable rather than returning false.
This makes it compose directly with `or_else`:

```lua
local result = fibers.perform(
  worker:can_op(stream, 'read')
    :and_then(stream:read_some_op(4096))
    :or_else(Op.always(nil, 'not authorised'))
)
```

The authority proof and protected action belong to one transaction. This avoids
a time-of-check/time-of-use gap between two separate `perform` calls.

A custom facility which relies on Grants should enforce the appropriate
`can_op` within the same Option as the protected operation.

### Issue a compatible Grant bundle

```lua
local rows = fibers.perform(Op.each({
  owner:grant_op(resource, reader, { 'read' }),
  owner:grant_op(resource, observer, { 'observe' }),
}))
```

Grants express permission, not locking. Several compatible Grants may coexist.
Exclusivity, leases, use limits or deadlines should be represented by the
subject facility or another transactional resource.

### Authority flow

Custodial authority flows down the Lifetime tree. A child Scope may use a live
obligation held by an ancestor without moving custody.

Grant authority also flows from the holder to its custodial descendants.
It does not flow upwards to ancestors, sideways to siblings, or onwards through
implicit sub-Grants.

Only the current subject custodian may issue a Grant.

### Transfer and revocation

Grants are non-transferable by default. Transferability is an explicit term.

Authority ends when:

- the Grant closes; or
- the subject closes.

Subject Closure invalidates every Grant over it immediately, even if a holder
has not yet retired the Grant Lifetime itself.

## 13. Focused transactional checks

Fibers does not provide a generic live topology snapshot. Where a protocol genuinely depends on current custody, use the focused predicate:

```lua
scope:has_custody_op(item)
```

The predicate participates in the same candidate world as the operation composed with it.

### Boolean reads do not reject a world

`has_custody_op(item)` succeeds with a Boolean. A false result is still a
successful Option, so this does not select the fallback:

```lua
-- Wrong if the intention is conditional availability.
scope:has_custody_op(item):or_else(fallback)
```

Convert the predicate into an unavailable Option when false:

```lua
local action = scope:has_custody_op(item):and_then(
  Op.guard(function(has_custody)
    if has_custody then
      return use_item_op(item)
    end
    return Op.never()
  end)
):or_else(fallback)
```

For authority-sensitive operations, `can_op` usually expresses the intended
condition more directly.

### Keep checks and actions together

This is unsafe as an authority protocol:

```lua
local allowed = fibers.perform(scope:has_custody_op(item))
if allowed then
  fibers.perform(use_item_op(item))
end
```

Custody may change between the two commits. Compose the observation and action
inside one Option whenever the observation must remain true for the action.

## 14. Closure

Closure is the monotonic process by which a Lifetime and everything beneath it
reach a terminal state.

```text
dormant
  │ admit
  ▼
live
  │ request close or cancel
  ▼
closing
  │ local consequence and descendants discharged
  ▼
retired
```

Natural body completion, cancellation and custodian-driven shutdown converge on
this lifecycle. Cancellation is not another state machine: it records close
intent with interruption requested, and the committed consequence interrupts the
local activity where one exists.

A failure while closing is recorded as a Closure fault while the Lifetime stays
`closing`. Retry or force acts on the retained closure obligation; neither is a
fifth lifecycle phase.

The practical guarantees are:

- requests travel parent-first;
- successful completion travels child-first;
- a parent does not report successful Closure while a descendant remains
  unresolved;
- completed partial work is retained;
- cleanup failure remains represented rather than being silently discarded.

### Starting structural closure

Structural closure deliberately has two transactions. The first transaction
claims responsibility and arranges the committed start of the closure driver:

```lua
local process = fibers.perform(
  scope:start_retire_op(resource, 'no longer needed')
)
```

`start_retire_op` is a normal transactional Option. It may be extended with
`map`, `and_then`, `each`, `together` or `or_else`:

```lua
local process = fibers.perform(
  scope:start_retire_op(resource, 'shutdown')
    :and_then(registry:write_op('closing'))
    :and_then(events:put_op('resource-closing'))
)
```

The CloseClaim, registry update, event and committed start consequence are one
possible world. If that complete world loses, none of them commits and no
closure driver starts.

The start consequence is an `emit`, not a `wrap`. Effect discharge only
schedules the already-accounted internal driver; it does not run resource
cleanup or perform further Options inside the effect phase.

### Observing completion

Closure progress occurs after the initiation transaction commits. Observe it in
a fresh transaction:

```lua
local ok, result = fibers.perform(process:result_op())
if not ok then
  error(result, 0) -- Closure.Failure
end
```

That observation is itself an ordinary Option and can be transactionally
sequenced:

```lua
fibers.perform(
  process:success_op()
    :and_then(registry:write_op('closed'))
    :and_then(events:put_op('resource-closed'))
)
```

This is the important causal boundary: **starting closure is transactional;
completion is a later transactional fact**. Completion cannot participate in
the transaction whose commit caused closure to begin.

For ordinary sequential code, `scope:retire(resource, reason)` performs both
stages and raises a retained `Closure.Failure` if the process fails.

### Close selection

Because initiation remains transactional, competing starts compose naturally:

```lua
local process = fibers.perform(Op.choice(
  scope:start_retire_op(primary, 'shutdown'),
  scope:start_retire_op(secondary, 'shutdown')
))
```

Only the selected complete world emits a start consequence. Once it commits,
external closure progress is not rollbackable.

### Structural order

For:

```text
root
├── a
│   └── a1
└── b
```

Closure requests proceed parent-first:

```text
root, a, a1, b
```

Finishing proceeds child-first in reverse structural order:

```text
b, a1, a, root
```

This lets a parent stop admitting work before children close while retaining the
parent infrastructure children may need during quiescence.

## 15. Closure failure and recovery

External Closure may make irreversible progress before a later descendant fails.
Fibers retains the truth rather than pretending the subtree returned to its
original live state.

A checked boundary may expose a `Closure.Failure`:

```lua
local result = fibers.try_scope(function(scope)
  -- work whose Closure may fail
end)

local failure = result.closure_failure
if failure then
  local report = failure:inspect()
  print(report.message)
end
```

The failure retains:

- completed progress;
- unresolved nodes;
- the failed closure step;
- custody blockers;
- current custody;
- an exclusive recovery capability.

### Retry or force

Recovery initiation is transactional in exactly the same way as initial
closure:

```lua
local process = fibers.perform(
  failure:retry_op()
    :and_then(metrics:increment_op('closure-retries'))
)
local ok, result = fibers.perform(process:result_op())
```

or, where the resource contract supports escalation:

```lua
local process = fibers.perform(failure:force_op())
local ok, result = fibers.perform(process:result_op())
```

The recovery authority is a one-shot Counter. Only one committed recovery world
can claim it; two `together` lanes cannot both retry or force the same failure.
A failed recovery publishes a new Failure with fresh authority. The retry/force
Option itself remains transactionally sequenceable because the committed driver
start is carried by `emit`, not `wrap`.

### Primary and secondary failures

A task body may fail and cleanup may also fail. Fibers retains both facts rather
than allowing cleanup failure to erase the body failure or disappear entirely.

Boundary reports distinguish:

- the primary failure;
- child failures;
- secondary failures;
- unresolved Closure failures.

## 16. Composition summary

Lifetime Options gain the meaning of every ordinary Option combinator.

### `choice`

Select one admission, transfer, cancellation, completion or Closure action.
Losing provisional topology changes do not commit.

```lua
Op.choice(
  source:move_op(session, worker_a),
  source:move_op(session, worker_b)
)
```

### `and_then`

Make responsibility or authority depend on an earlier action in the same
transaction.

```lua
request:get_op():and_then(
  Op.guard(function(value)
    return scope:spawn_op(function()
      return handle(value)
    end)
  end)
)
```

### `or_else`

Use a fallback only when the complete preferred Lifetime action cannot happen
now.

```lua
scope:spawn_op(run_request)
  :or_else(Op.always(nil, 'not accepting now'))
```

### `each`

Commit independent admissions, movements, Grants or cancellation requests
together.

```lua
Op.each({
  first:request_cancel_op('shutdown'),
  second:request_cancel_op('shutdown'),
  status:write_op('stopping'),
})
```

### `together`

Allow negotiated Lifetime actions to supply one another.

```lua
Op.together({
  source:offer_op(item, destination),
  destination:accept_op(),
})
```

### `map` and `guard`

Shape provisional handles and choose the next Lifetime operation. Their callbacks
remain speculative and replayable.

### `wrap`

Continue a particular participant after commitment. `wrap` is intentionally a
post-commit result boundary, so its result cannot feed back into transactional
`map` or `and_then`.

Structural Closure does **not** use `wrap`. `start_retire_op`, `retry_op` and
`force_op` carry their committed driver start with `emit`, so their returned
`Closure.Process` remains a transactional value. Each process attempt publishes its result through an ordinary Completion and is observed
later through `success_op`, `failure_op` or `result_op`.

## 17. Common patterns

### Transactional service admission

Receive work only if its handler can be admitted and owned.

### Atomic subsystem start

Admit all required participants with `each`, or start none.

### Safe replacement

Choose deliberately between replacement after body exit and replacement after
complete Lifetime outcome.

### Deadline with accountable cancellation

Commit the cancellation request in the deadline branch, then observe the complete
outcome.

### Resource adoption

Acquire under temporary bootstrap custody and move the complete subtree to its
permanent supervisor only after initialisation succeeds.

### Negotiated work distribution

Offer work to a receiver which can accept responsibility now, moving custody with
delivery.

### Borrowing without transfer

Retain custody while granting temporary rights to another Scope.

### Plugin capability boundary

Keep shared host resources under host custody while Grants give a plugin only the
rights it requires. Closing the plugin closes its Tasks and Grants without moving
host responsibility.

### Protocol hand-off

Commit protocol state, acknowledgement and custody movement as one complete
action.

### Recovery delegation

Pass one `Closure.Failure` to a designated recovery supervisor. Its linear
capability prevents competing recovery attempts.

## 18. Scope results and practical questions

| Question | Use |
|---|---|
| What values did the scope body return? | raising boundary return values or `ScopeResult:unpack()` |
| Did the Task body return, fail or receive cancellation? | `Task:body_result_op()` |
| Did the complete Task Lifetime resolve? | `Task:outcome_op()` or `Task:await()` |
| Has cancellation been requested? | `cancel_requested_op()`, optionally composed with `or_else` for a present alternative |
| Does this Scope currently hold a consequence? | `Scope:has_custody_op()` when a protocol genuinely needs the predicate |
| May this Scope perform a protected action? | compose `Scope:can_op()` with that action |
| Which child or cleanup failures occurred? | checked Scope result and report |
| Can unresolved Closure be retried or forced? | retained `Closure.Failure` |

## 19. Boundaries and qualifications

### Process-local tree

A Lifetime belongs to one Runtime-local tree. It cannot move between Runtime
instances or processes.

Distributed ownership requires a higher-level protocol.

### Cooperative cancellation

Cancellation cannot pre-empt arbitrary Lua or foreign code.

### Grants are not a language sandbox

Grants are a capability-oriented runtime protocol. A facility must enforce the
relevant right through `can_op` or an equivalent protected operation. Raw debug
or implementation access remains trusted.

### Rights are facility-defined

Strings such as `read`, `write` and `observe` gain meaning through the facility
which checks them. Version 1 does not impose one universal rights ontology.

### Ordinary Lua mutation is not transactional

Only changes represented by Fibers facilities participate in rollback and
commitment.

### Closure crosses a real causal boundary

Admission, movement, Grant issuance, cancellation request and closure initiation
are provisional managed actions. When a closure-start world commits, its emitted
consequence starts external progress which cannot generally be rolled back. The
result of that progress is therefore observed in a later transaction.

## 20. Practical rules

1. Admit continuing work to a Scope rather than detaching it.
2. Compose admission with the communication or state change which justifies it.
3. Choose nursery or supervisor policy deliberately.
4. Distinguish body completion from complete Lifetime outcome.
5. Treat cancellation as a cooperative request and Closure as complete accounting.
6. Move custody transactionally when responsibility changes.
7. Use negotiated offer and acceptance when the receiver must participate.
8. Use Grants for authority without responsibility transfer.
9. Compose authority checks with the protected action.
10. Compose `start_retire_op` or recovery initiation transactionally with the state changes that justify them.
11. Observe Closure completion through the returned `Closure.Process` in a later transaction.
12. Retain and resolve Closure failures rather than suppressing them.
13. Keep cancellation masks and suspension-free regions small and explicit.

The deeper rule is:

> Lifetime operations let responsibility and authority participate in the same
> complete action as communication and managed state.
