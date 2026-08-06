# Options

This is the complete practical guide to the Fibers option algebra. It defines how application programs should read and use options without requiring knowledge of the execution kernel.

For the more exact semantic account, see [The option algebra](../advanced/option-algebra.md). For signatures, see the [API reference](../api-reference.md).

## Direct actions and inert options

A direct facility method performs an action:

```lua
local value = channel:get()
```

Its `_op` form describes the same action:

```lua
local receive = channel:get_op()
```

Perform the description with:

```lua
local value = fibers.perform(receive)
```

The two forms have the same values, errors, cancellation and lifetime effects.

Use direct methods for ordinary sequential fiber code. Ask for an option when the action must be combined with another possible action.

## `perform`

```lua
local a, b = fibers.perform(option)
```

`perform` selects and commits one coherent result. It preserves exact Lua multiple returns, including nils.

`perform` may complete immediately. It suspends only when the option cannot yet commit and the current execution contract permits suspension.

## Immediate and impossible options

```lua
Op.always(value, ...)
Op.never()
```

`always` provides an immediately available result. `never` provides no possible result.

Useful identities include:

```text
choice()              = never
choice(never, a)      = a
```

Options remain opaque values. Combine them through the public API rather than altering their table representation.

## `choice`: unordered permission

```lua
Op.choice(a, b, ...)
Op.choice({ a, b, ... })
```

`choice` means:

> Any coherent alternative is acceptable.

Source position does not express priority. If several alternatives can commit, Fibers may select any permitted occurrence.

Losing alternatives install no state and discharge no committed effects.

```lua
local result = fibers.perform(Op.choice(
  replies:get_op(),
  shutdown:get_op()
))
```

Use `or_else`, not branch order, when a fallback is allowed only after a preferred action cannot happen now.

### Named choice results

```lua
local kind, value = fibers.perform(Op.named_choice({
  reply = replies:get_op(),
  shutdown = shutdown:get_op(),
}))
```

The selected key is returned before the branch values. Keys are sorted for portable construction; that order is not semantic priority.

## `map`: transform provisional results

```lua
local labelled = replies:get_op():map(function(reply)
  return 'reply: ' .. reply
end)
```

A `map` callback helps define a candidate result. It may be revisited while Fibers explores alternatives.

It must be:

- deterministic for its explicit inputs;
- non-yielding;
- free of irreversible I/O;
- free of externally visible mutation.

Use `wrap` for ordinary application work after commitment.

## `and_then`: transactional sequence

```lua
local admit = capacity:take_op(1)
  :and_then(requests:put_op(request))
```

`and_then` means:

> Satisfy the first option and then the second as one transaction.

The first option remains provisional until the second also succeeds. If the residual world fails, the earlier work is retracted.

The right-hand side is an option, not a function.

## `guard`: construct a dynamic residual

Use `guard` when the next option depends on provisional values:

```lua
local exchange = requests:get_op():and_then(
  Op.guard(function(request)
    return responses:put_op(handle(request))
  end)
)
```

The guard receives the immediately preceding values as ordinary Lua varargs. Nil values and exact arity are preserved.

A root guard receives no arguments:

```lua
local fresh = Op.guard(function()
  return build_fresh_option()
end)
```

A guard callback follows the same speculative discipline as `map`. It may allocate fresh private values, but it must not perform, yield, drive the Runtime or mutate transactional state outside the returned option.

## `or_else`: present fallback

```lua
preferred:or_else(fallback)
```

This means:

> Use the preferred option if it can happen now; otherwise consider the fallback.

“Can happen now” means that a coherent transaction can commit without waiting for a future change. The presently committable world may involve other current participants, alternative matches, provisional state or several compatible operations.

```lua
local action = attack_op(agent, target)
  :or_else(take_cover_op(agent))
  :or_else(return_to_patrol_op(agent))
```

Fibers does not permit the fallback merely because one attempted match failed or an internal work budget was exhausted. Bounded evaluation may continue later without changing the application law.

### `or_else` is not a timeout

Use a timer when the statement concerns elapsed time:

```lua
local result = fibers.perform(Op.choice(
  reply_op,
  Sleep.sleep_op(5):map(function()
    return nil, 'deadline reached'
  end)
))
```

Use `or_else` when the statement concerns what can happen now.

## Products

Products require every lane to succeed in one transaction.

### `each`: independent support

```lua
local rows = fibers.perform(Op.each({
  camera_capacity:take_op(1),
  animation_capacity:take_op(1),
}))
```

Every lane must be supportable from the common parent world. Siblings may constrain one another through shared state, but one lane cannot positively supply another.

### `together`: interacting support

```lua
local rows = fibers.perform(Op.together({
  flow:inlet():write_op('GO'),
  flow:outlet():read_some_op(2),
}))
```

Every lane must succeed, and compatible siblings may make one another possible.

Use `together` for intentional internal hand-off, cyclic exchange or coordinated transfer.

### Product results

A product returns an array of nil-preserving packed rows:

```lua
local rows = fibers.perform(Op.each(
  Op.always('a', nil, 'c'),
  Op.always(42)
))

assert(rows[1].n == 3)
assert(rows[1][1] == 'a')
assert(rows[1][2] == nil)
assert(rows[1][3] == 'c')
assert(rows[2][1] == 42)
```

`Op.named_each` returns a table keyed by lane name. A single-valued lane is projected directly; the original packed rows remain available through `_rows`.

## `wrap`: participant continuation after commitment

```lua
local shown = voice_lines:get_op():wrap(function(line)
  subtitle_panel:set_text(line)
  return line
end)
```

A `wrap` callback runs after the selected world has committed, when that participant resumes.

It may:

- update ordinary Lua objects;
- log;
- perform further options;
- spawn work;
- call application code.

It cannot alter the transaction which already committed.

A wrapped option cannot subsequently be extended with `map` or `and_then`; build the complete transaction first, then wrap it.

## Labels

```lua
local next_event = Op.choice(
  commands:get_op():label('receive-command'),
  shutdown:get_op():label('receive-shutdown')
):label('select-service-event')
```

Option labels are immutable diagnostic annotations. Labelling returns a new option and leaves the original unchanged.

Labels do not alter matching, priority, results or commitment. They identify meaningful application operations in diagnostics and instrumentation.

## Defeat obligations

```lua
option:on_defeat(effect)
```

A defeat obligation belongs to one entered competing occurrence. It is discharged when an incompatible competitor commits.

It does not run merely because:

- a search remains incomplete;
- an `or_else` fallback is considered;
- an occurrence was never entered;
- the preferred side is presently absent.

This is an advanced facility. See [Effects](../advanced/extending.md#committed-effects).

## Cancellation

A performed option participates in the current scope’s cancellation and Closure rules. Cancellation is cooperative and is observed at recognised Fibers boundaries.

A transaction which commits before cancellation wins returns normally. A pending operation may instead finish through the current cancellation path.

Use `fibers.mask` or `Scope:mask` only for small regions whose cancellation policy is deliberately deferred. Masking does not make blocking foreign code safe.

## Suspension-free regions

`fibers.without_suspension(fn, ...)` permits immediate option commitment but rejects an actual scheduling hand-off.

```lua
fibers.without_suspension(function()
  local value = fibers.perform(
    preferred:or_else(Op.always(default))
  )
  update_model(value)
end)
```

See [Execution and observability](../advanced/execution-and-observability.md).

## Common patterns

### Timeout

```lua
Op.choice(work_op, Sleep.sleep_op(seconds):map(timeout_result))
```

### Try now

```lua
preferred:or_else(Op.always(fallback_value))
```

### Reserve and publish

```lua
capacity:take_op(1):and_then(queue:put_op(value))
```

### Receive and reply atomically

```lua
requests:get_op():and_then(Op.guard(function(request)
  return responses:put_op(handle(request))
end))
```

### Label one application decision

```lua
complex_option:label('admit-request')
```

### Post-commit application work

```lua
transaction:wrap(apply_result)
```

## Practical rules

1. Use direct methods until composition is useful.
2. Read `choice` as permission, not priority.
3. Read `or_else` as present fallback, not elapsed-time fallback.
4. Use `and_then` for one complete transactional sequence.
5. Use `each` when lanes stand independently; use `together` for intended sibling supply.
6. Keep `map`, `guard` and facility transitions replayable.
7. Put ordinary application effects in `wrap` or committed effects.
8. Label only boundaries which improve observation.
