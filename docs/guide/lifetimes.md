# Lifetimes

This guide is the complete practical account of tasks, scopes, cancellation, child-failure policy and Closure.

For custody movement, Grants and the complete authority model, see [Custody, Grants and Closure](../advanced/custody-grants-and-closure.md). For exact signatures, see the [API reference](../api-reference.md).

## Why Lifetimes exist

A coroutine can finish while consequences it created remain alive. Fibers therefore distinguishes:

- executing a function;
- the result of its body;
- the continuing resources and children associated with it;
- the complete outcome after those consequences close.

A Lifetime records that continuing responsibility.

## Root scope

```lua
fibers.run(function(scope)
  -- body
end)
```

`fibers.run` creates a Runtime and root scope, drives the program, accounts for retained custody, then closes the Runtime.

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

## Tasks

```lua
local task = scope:spawn(function()
  return do_work()
end)
```

A Task is structured continuing work admitted to a scope.

Useful operations include:

```lua
task:await_op()
task:body_result_op()
task:outcome_op()
task:request_cancel_op(reason)
task:cancel_requested_op()
task:state_op()
```

Direct forms exist for `await` and `request_cancel`.

### Awaiting

```lua
local value = task:await()
```

`await` waits for the complete task outcome and raises structured failure where appropriate. It is not merely a join on the body coroutine.

### Body result and complete outcome

Use `body_result_op` when the question is:

> How did the task body itself finish?

Use `outcome_op` or `await_op` when the question is:

> Has the complete task Lifetime, including retained consequences, resolved?

These can differ. A body may return before a retained Stream closes, or cleanup may fail after a successful return.

## Nested scopes

```lua
local value = fibers.scope(function(scope)
  scope:spawn(run_reader)
  scope:spawn(run_writer)
  return wait_for_result()
end)
```

The checked form is `fibers.try_scope`.

A nested scope creates a responsibility boundary. It accounts for its retained descendants before returning.

Use a scope when a group of tasks or resources should:

- share one lifetime;
- close together;
- apply one child-failure policy;
- move as one responsibility subtree;
- produce one boundary report.

## Nursery policy

The root scope is a nursery.

When a nursery child fails, the boundary:

- records the failure;
- seals further admission where required;
- requests cancellation or Closure of remaining siblings;
- accounts for retained descendants;
- fails the boundary.

This is the ordinary structured-concurrency policy for work whose failures should not be ignored.

## Supervisor policy

A supervisor applies an explicit alternative child-failure policy.

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

Supported policy details are defined by `Closure.supervisor`. Use a supervisor when the parent deliberately owns the decision about how child failures affect the boundary.

A supervisor is not an unstructured escape hatch: retained work still belongs to the scope and must reach Closure.

## Cancellation

Cancellation is a cooperative request represented within the Lifetime system.

```lua
local task = scope:spawn(run_worker)

-- elsewhere
local ok = task:request_cancel('service stopping')
```

A fiber observes cancellation at a cooperating Fibers operation or another recognised cancellation point.

Cancellation cannot pre-empt:

- an infinite CPU loop;
- a blocking foreign function;
- non-cooperative host code;
- application code which never reaches a suspension boundary.

### Cancellation and Closure

Cancellation requests that work stop. Closure accounts for the entire continuing consequence and establishes whether it actually reached a terminal state.

A cancellation request may be observed while Closure still has descendants or resources to resolve.

## Masking

```lua
fibers.mask(function()
  finish_small_critical_bookkeeping()
end)
```

`mask` defers ordinary cancellation observation within a dynamic region. It should be small and deliberate.

Masking does not:

- prevent a blocking foreign call;
- make ordinary Lua mutation transactional;
- guarantee that the region is fast;
- replace `without_suspension`.

Use `without_suspension` when the contract is specifically that no scheduling hand-off may occur.

## Closure

Closure is the monotonic process by which a Lifetime and everything beneath it reach a terminal state.

Important application guarantees are:

- requests travel parent-first;
- successful completion travels child-first;
- a parent does not report successful Closure while a descendant remains unresolved;
- completed partial work is retained;
- cleanup failure remains represented rather than being silently discarded.

### Closure failure

A checked scope result may contain a `Closure.Failure` when obligations could not complete.

The failure retains an exclusive recovery capability. The application may inspect it and explicitly retry or force unresolved Closure according to the facility’s contract.

Successful siblings are not repeated merely because another descendant failed to close.

### Primary and secondary failures

A task body may fail and cleanup may also fail. Fibers retains both facts rather than allowing cleanup failure to erase the body failure or disappear entirely.

Boundary reports distinguish the primary failure from secondary failures and unresolved Closure.

## Scope reports and checked results

The practical questions map to different values:

| Question | Use |
|---|---|
| What values did the scope body return? | `ScopeResult:unpack()` or raising boundary return values |
| Did the task body return, fail or receive cancellation? | `Task:body_result_op()` |
| Did the complete task Lifetime resolve? | `Task:outcome_op()` or `Task:await()` |
| Which child or cleanup failures occurred? | checked scope report/result |
| Can unresolved Closure be retried or forced? | retained `Closure.Failure` |

## Custody

Every live Lifetime has one custodial parent. Custody answers:

> Who remains responsible for ensuring this consequence eventually closes?

Application code normally encounters custody through scopes and admitted tasks.

Advanced programs can compose custody operations transactionally:

```lua
scope:admit_op(value)
scope:move_op(value, target)
scope:offer_op(value, target, terms)
scope:accept_op(filter)
```

These operations can commit with the communication or state change which justifies the responsibility transfer.

See [Custody, Grants and Closure](../advanced/custody-grants-and-closure.md).

## Grants

A Grant confers authority without changing custody.

Use Grants when another scope or component should be allowed to perform specified operations while responsibility remains with the current custodian.

Rights, transferability, revocation and subject Closure are explicit. A Grant is not a second ownership tree.

## Labels

Tasks and scopes may be labelled for diagnostics:

```lua
local session = fibers.scope({ label = 'current-session' }, function(scope)
  return scope:spawn(run_session)
    :label('session-coordinator')
    :await()
end)
```

Labels remain separate from stable Lifetime identity and do not affect custody or authority.

Most local tasks need no label. Labels are most useful at long-lived service, supervision and resource boundaries.

## Coordinator pattern

A long-lived coordinator can keep one explicit blocking frontier and reduce selected events without suspension:

```lua
while true do
  local event = fibers.perform(next_event_op(state))

  fibers.without_suspension(function()
    reduce_event(state, event)
  end)
end
```

This protects ordinary Lua invariants between the selected event and the return to the outer frontier.

## Practical rules

1. Admit continuing work to a scope rather than detaching it.
2. Choose nursery or supervisor policy deliberately.
3. Distinguish body completion from complete Lifetime outcome.
4. Treat cancellation as cooperative request and Closure as complete accounting.
5. Keep cancellation masks small.
6. Retain and resolve Closure failures rather than suppressing them.
7. Move custody transactionally when responsibility changes.
8. Use Grants for authority without responsibility transfer.
