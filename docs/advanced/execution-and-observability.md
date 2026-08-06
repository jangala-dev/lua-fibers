# Execution and observability

Fibers exposes a small number of dynamic execution contracts. They constrain when code may suspend or perform effects without changing the option algebra itself.

This document also defines diagnostic labels, which attach human vocabulary to Runtime identities and option occurrences.

## Fiber turns

A fiber turn is a maximal stretch during which one fiber retains execution before another fiber or the host may run.

A call to `perform` does not necessarily end a turn. If the option commits immediately and the same fiber continues before another application fiber is allowed to run, the turn continues.

A turn ends when:

- the fiber remains pending;
- another application fiber is permitted to execute first;
- control returns to the embedding host;
- the fiber completes or fails.

This boundary is useful for both scheduling assertions and profiling.

## `without_suspension`

```lua
fibers.without_suspension(fn, ...)
```

The function must begin and finish without the current fiber relinquishing execution.

The call:

- preserves all return values, including nils;
- preserves ordinary Lua errors;
- may be nested;
- permits `perform` where the selected option commits without ending the turn.

```lua
local value = fibers.without_suspension(function()
  return fibers.perform(
    preferred:or_else(Op.always(default))
  )
end)
```

Fibers raises a `suspension_error` before:

- parking the current fiber;
- allowing another application participant to resume first;
- returning to the host because a bounded search quantum was exhausted.

The option retains its ordinary meaning. The execution contract does not ignore presently relevant participants or permit an `or_else` fallback merely to avoid suspension.

### Coordinator use

```lua
while true do
  local event = fibers.perform(
    next_event_op(state):label('device.next-event')
  )

  fibers.without_suspension(function()
    reduce_event(state, event)
  end)
end
```

This protects a common coordinator invariant:

1. wait at one explicit event frontier;
2. reduce the selected event to a new quiescent state;
3. return to the frontier without hidden interleaving.

### Other uses

The same contract is useful for:

- ordinary-Lua reducers which must restore an invariant before interleaving;
- callbacks whose documented contract is non-suspending;
- borrowed host values which must not survive a yield;
- final bookkeeping inside a facility;
- code invoked while a foreign host holds a lock or temporary borrow.

### What it is not

`without_suspension` is not:

- a transaction;
- a lock;
- rollback for ordinary Lua mutation;
- a duration limit;
- protection from a foreign call which blocks without returning to Fibers;
- cancellation masking.

A region may remain suspension-free and still hold the scheduler for too long.

## Speculative callback contracts

Several callbacks help describe a possible committed world and may be replayed:

- `Op:map` transforms;
- `Op.guard` builders;
- resource transition functions;
- witness factories and predicates;
- effect keying, merging and preparation.

They must be:

- deterministic for explicit inputs;
- non-yielding;
- free of irreversible I/O;
- free of externally visible mutation;
- independent of ambient transactional facts not supplied explicitly.

Fibers prohibits recognised scheduling operations in these phases. Lua cannot prevent all mutation of arbitrary tables or globals, so this remains a trusted-code contract.

Use `wrap` for participant-local application work after commitment.

## Cancellation masks

```lua
fibers.mask(fn, ...)
Scope:mask(fn, ...)
```

A mask defers ordinary cancellation observation within a dynamic region. It does not prohibit suspension and does not make the region atomic.

Use:

- `mask` when cancellation observation must be deferred;
- `without_suspension` when scheduling hand-off must be prohibited;
- transactional options when state or communication must commit atomically.

These contracts are independent and may be combined deliberately.

## Labels

Fibers assigns stable internal identities to Runtimes, fibers, Lifetimes and resources. Labels add optional human context.

### Identity-bearing objects

Resources, Tasks, Scopes, Lifetimes and supported host handles use fluent mutable diagnostic labels:

```lua
local commands = channel.new(16)
  :label('service-commands')

local worker = scope:spawn(run_worker)
  :label('configuration-watcher')
```

Calling `:label()` without an argument returns the current label where supported. Calling `:label(nil)` clears it.

A label:

- need not be unique;
- may change;
- does not participate in equality;
- does not replace the stable internal ID;
- does not affect matching, scheduling, custody or authority.

### Options

Options are immutable values. Labelling returns a new option:

```lua
local receive = commands:get_op()
local primary = receive:label('receive-primary-command')
local fallback = receive:label('receive-fallback-command')
```

The original `receive` remains unchanged.

A label may mark a whole application operation or an internal boundary:

```lua
local admit_request = capacity:take_op(1)
  :label('reserve-capacity')
  :and_then(
    requests:put_op(request)
      :label('publish-request')
  )
  :label('admit-request')
```

Repeated performance of one labelled option produces distinct dynamic occurrences. The label groups semantically related work; occurrence identity distinguishes individual attempts.

### Structural descriptions

Composite facilities derive diagnostic descriptions structurally rather than making labels part of construction. A labelled channel may therefore expose internal descriptions such as:

```text
service-commands
├── items
└── slots
```

The children retain their own stable identities. A later parent label can be resolved when diagnostics are rendered.

## Profiling model

The same native boundaries support profiling without requiring a separate application framework:

- Task or Lifetime identity says which participant ran;
- an option label says which application decision was active;
- a resource label says which facility was involved;
- an option occurrence identifies one attempt;
- a fiber turn measures uninterrupted scheduler possession;
- a search session accounts for kernel work used to satisfy one perform attempt.

A profiler can therefore answer:

- Which fiber held execution for too long?
- Which application operation was active?
- Was time spent in application code, proof search or a host call?
- Which resource was awaited?
- Which Lifetime owns unresolved work?
- Where did a suspension-free region attempt to yield?

The public label contract is stable independently of any particular report format or exporter.

## Internal mechanism

The Runtime maintains a dynamic execution context for the currently resumed fiber. Public `without_suspension`, speculative callback phases and internal facility contracts use the same underlying suspension-permission mechanism while retaining distinct error categories and diagnostics.

This keeps the mechanism general internally without exposing a generic policy-region framework publicly.
