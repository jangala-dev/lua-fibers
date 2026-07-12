# Programming guide

This guide covers the ordinary application-facing use of `fibers`. See `algebra.md` for semantics, `lifetimes.md` for custody and settlement, and `embedding.md` for direct runtime driving.

## Runtime, scopes and fibres

Most programmes begin with `fibers.run`:

```lua
local fibers = require('fibers')

fibers.run(function(scope)
  local task = scope:spawn(function()
    return 'done'
  end, 'worker')

  assert(fibers.perform(task:await_op()) == 'done')
end)
```

`fibers.run` creates a runtime, a root scope and a standalone runner. The callback receives the root scope.

`fibers.spawn` is shorthand for spawning in the current scope:

```lua
fibers.run(function()
  local task = fibers.spawn(function()
    return 7
  end)
  assert(fibers.perform(task:await_op()) == 7)
end)
```

The default nursery policy rejects high-level unstructured spawning. `fibers.spawn_raw` is permitted only when the current policy allows it. Embedders may call `Runtime:spawn_raw` directly at the driver boundary.

Nested scopes use `fibers.scope`:

```lua
local result = fibers.scope(function(scope)
  local task = scope:spawn(function() return 7 end)
  return fibers.perform(task:await_op())
end)

assert(result == 7)
```

The raising forms `run` and `scope` return body values or raise after the boundary has accounted for retained custody. `try_run` and `try_scope` return a `ScopeResult`:

```lua
local outcome = fibers.try_scope(function()
  return 'ok'
end)

if outcome.ok then
  assert(outcome:unpack() == 'ok')
else
  print(outcome:tostring())
end
```

## Operations

An `Op` is an inert transaction description. Constructing one does not perform it.

```lua
local op = fibers.always(42)
assert(fibers.perform(op) == 42)
```

Common combinators are:

```text
op:map(function(...) ... end)
op:and_then(function(...) return another_op end)
op:or_else(fallback_op)
op:wrap(function(...) ... end)
op:on_defeat(effect)
```

`map`, `and_then`, `guard` and primitive transition callbacks execute during speculative proof search. They must be deterministic, non-yielding and free of irreversible side effects.

`wrap` executes for the resumed participant after commit. It may perform another operation.

### Choice

`choice` is unordered disjunction:

```lua
local value = fibers.perform(fibers.choice(
  left:get_op(),
  right:get_op()
))
```

If both branches can commit, either result is valid; the first branch has no special status. Unbiased here means absence of source-position priority, not statistical uniformity. A winning branch commits. Other entered branches may contribute typed defeat obligations. Retry, validation conflict and bounded-search incompleteness are not defeat.

The runtime uses a deterministic traversal derived from `choice_seed`:

```lua
local rt = fibers.Runtime.new({ choice_seed = 17 })
```

The same seed reproduces branch traversal when the programme, request sequence and external inputs are also the same. `choice` does not promise fairness or uniform probability.

### Principled immediate fallback

`or_else` provides validated instantaneous priority:

```lua
local value = fibers.perform(
  cache:get_op(key):or_else(fibers.always(default_value))
)
```

The fallback becomes eligible only after the preferred search scope has been completely refuted under recorded managed facts. A bounded `Unknown` never opens the fallback. The negative proof is validated again with the fallback before commit.

This composes naturally with unordered choice:

```lua
local event = fibers.perform(
  socket:readable_op():or_else(fibers.choice(
    shutdown:wait_op(),
    maintenance:wait_op()
  ))
)
```

Socket readiness has semantic priority at the commit point. If it is absent in the managed world, either eligible secondary event may be selected without source-order preference. To put several operations in the preferred tier, write `fibers.choice(a, b):or_else(fallback)`; the fallback opens only when the complete choice has been refuted.

### Products

`all` combines independent lanes in one commit:

```lua
local rows = fibers.perform(fibers.all({
  left:take_op(1),
  right:take_op(1),
}))
```

Product results are row values. Each row preserves the number of values returned by its lane, including nil values.

`tensor` additionally permits sibling hand-off:

```lua
fibers.perform(fibers.tensor({
  slots:give_op(1),
  slots:take_op(1),
}))
```

In both modes, all lane deltas must form one coherent final world. Under `all`, sibling changes may constrain or invalidate another lane but cannot positively supply readiness. Under `tensor`, compatible supply is visible.

Use `all` for joint requirements which must each be satisfiable without sibling supply. Use `tensor` for protocols where lanes intentionally communicate or transfer transactional stock.

## Rendezvous and channels

A `Rendezvous` is an unbuffered synchronous exchange:

```lua
local meeting = fibers.Rendezvous.new('jobs')

local send = meeting:put_op({ id = 1 })
local receive = meeting:get_op()
```

Put and get commit together. Pairing is provisional until both participants and their continuations close.

`Channel` is a convenience façade:

```lua
local unbuffered = fibers.Channel.new(0)
local buffered = fibers.Channel.new(16)
```

Both expose `put_op` and `get_op`; the bounded form is implemented as a queue.

## Transactional state and allocation

### Scalar

Use `Scalar` for one replaceable fact:

```lua
local state = fibers.Scalar.new({ open = true, count = 0 }, 'state')

local increment = state:read_op():and_then(function(old)
  if not old.open then return fibers.never() end
  return state:write_op({ open = true, count = old.count + 1 })
end)

fibers.perform(increment)
```

For an ordered state machine, define a typed transition:

```lua
local Increment = fibers.Scalar.transition {
  name = 'counter.increment',
  mode = 'update',
  validate = function(payload)
    assert(type(payload.by) == 'number', 'by must be a number')
  end,
  step = function(value, payload)
    local next_value = value + payload.by
    return fibers.Scalar.Ready.write(next_value, next_value)
  end,
}

local counter = fibers.Scalar.machine(0, 'counter')
local next_value = fibers.perform(counter:transition_op(Increment, { by = 1 }))
assert(next_value == 1)
```

Transition modes are `update`, `select` and `query`. The callback returns `Scalar.Ready.write`, `Scalar.Ready.same`, or no ready value. See `resource-authoring.md` before writing primitive transitions.

### Counter, Keyed, Index and Lease

```lua
local permits = fibers.Counter.new({ initial = 4, min = 0, max = 4 })
fibers.perform(permits:take_op(1))
fibers.perform(permits:give_op(1))

local keyed = fibers.Keyed.new()
fibers.perform(keyed:put_op('key', 'value'))
assert(fibers.perform(keyed:get_op('key')) == 'value')

local index = fibers.Index.new()
fibers.perform(index:insert_op('a', 10, 'value'))
local entry = fibers.perform(index:pop_first_op())
assert(entry.key == 'a')

local leases = fibers.Lease.new({
  read = { read = true },
  write = {},
})
fibers.perform(leases:acquire_op('document', 'read', 'worker-1'))
fibers.perform(leases:release_op('document', 'worker-1'))
```

These facilities obey the same product law. For example, a sibling insertion may supply a Keyed get under `tensor`, but not under `all`.

## Compound coordination facilities

The following are ordinary Lua facilities over the fixed transaction substrate:

```text
Queue          ordered bounded queue
PriorityQueue  ordered bounded queue with ranks
Pulse          level-like notification
WaitGroup      structured count-to-zero coordination
Mailbox        buffered or rendezvous messaging endpoints
Pool           indexed allocation with keyed and lease state
RateLimiter    token-bucket Scalar machine
Task           Region-owned structured fibre
Scope          Region, Task and policy boundary
Flow           transactional byte reservoir and endpoints
Stream         two Flows plus optional host pumps
```

Example:

```lua
local wg = fibers.WaitGroup.new()
fibers.perform(wg:add_op(1))
fibers.perform(wg:done_op())
fibers.perform(wg:wait_op())
```

## Witnessed facilities: Petri and Calendar

`Petri` expresses coloured linear-multiset transitions. A transition may have several token bindings; the kernel searches those bindings globally and may backtrack if another lane later fails.

```lua
local net = fibers.Petri.new({
  jobs = { { id = 1, priority = 10 } },
  workers = { 'alice' },
})

local start = net:transition {
  name = 'start',
  inputs = {
    { place = 'jobs', as = 'job' },
    { place = 'workers', as = 'worker' },
  },
  produce = function(binding)
    return {
      running = {
        { job = binding.job, worker = binding.worker },
      },
    }
  end,
  result = function(binding)
    return binding.job, binding.worker
  end,
}

local job, worker = fibers.perform(net:fire_op(start))
```

`Calendar` searches feasible intervals across one or more named resources:

```lua
local calendar = fibers.Calendar.new()

local booking = fibers.perform(calendar:reserve_op {
  resources = { 'room-a', 'alice' },
  earliest = 9,
  latest = 17,
  duration = 1,
  preference = 'earliest',
  payload = { purpose = 'review' },
})

fibers.perform(calendar:cancel_op(booking.id))
```

Both facilities use lazy witness cursors owned by the kernel search. They do not run private solvers.

## External facts and time

Create runtime-bound external resources through the runtime. Feed delivery is an external-driver action and is not permitted from an ordinary fibre:

```lua
local rt = fibers.Runtime.new({ host = fibers.host.manual() })
local signal, feed = rt:signal('shutdown')
local result

rt:spawn_raw(function()
  result = rt:perform(signal:wait_op())
end, 'waiter')

rt:run()                 -- waiter becomes pending
feed:set('requested')    -- external driver delivery
rt:run()
assert(result == 'requested')
```

A `Signal` is latched. `EventQueue` stores externally delivered occurrences which are consumed transactionally. `Readiness` records level-like read or write hints. `Clock` observes host time.

Application code normally sleeps through:

```lua
fibers.perform(fibers.sleep_op(0.25))
```

The relative deadline is fixed once per perform attempt; validation restart does not slide it forwards.

## Effects and participant aftermath

An effect is runtime-owned work selected with a committed world:

```lua
local op = fibers.after_commit(effect)
```

Effect preparation occurs before state installation. Discharge occurs after installation and before selected fibres resume. A discharge failure is fatal because the committed state cannot be rolled back.

`op:on_defeat(effect)` attaches an obligation to an entered occurrence which loses to a committed competitor.

`wrap` is different: it transforms one participant's committed result after the transaction has committed and may begin a new transaction.

## Scopes, custody and settlement

Most lifetime-bearing values should be created or admitted inside a scope:

```lua
fibers.scope(function(scope)
  local task = scope:spawn(function()
    return 'ok'
  end)

  assert(fibers.perform(task:await_op()) == 'ok')
end)
```

The principal lifetime verbs are:

```text
admit     enter custody
move      transfer custody atomically
borrow    grant temporary authority without moving custody
seal      reject new custody
claim     take exclusive settlement authority
resolve   discharge, fail or restore a claim
```

See `lifetimes.md` before directly using `Region`, claims, custom settlement or borrowing.

## Flows and streams

A `Flow` is a unidirectional transactional byte reservoir:

```lua
local flow = fibers.Flow.new({ capacity = 4096 })
local inlet = flow:inlet()
local outlet = flow:outlet()

fibers.perform(inlet:write_op('abc'))
assert(fibers.perform(outlet:read_exactly_op(3)) == 'abc')
```

A `Stream` is bidirectional:

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
assert(fibers.perform(b:reader():read_line_op()) == 'hello')
```

Important properties include:

```text
losing writes append nothing
losing reads consume nothing
read_exactly does not consume an incomplete prefix
peek does not free capacity
active leases retain capacity
producer closure yields EOF after retained bytes drain
consumer closure settles retained bytes as failure
```

Host-backed streams are opened transactionally:

```lua
local stream = fibers.perform(
  fibers.Stream.open_backend_in_op(scope:raw_region(), backend, {
    name = 'connection',
  })
)
```

If the open operation loses, no pump starts. Use `stream:reader()` and `stream:writer()` as the stable authority-bearing endpoints. See `embedding.md` for backend and HostHandle contracts.

## Errors and protected calls

Use `fibers.pcall` and `fibers.xpcall` when protected code may suspend:

```lua
local ok, value = fibers.pcall(function()
  return fibers.perform(op)
end)
```

These helpers provide yieldable protection on Lua 5.1 as well as later versions.

## Further reading

- `algebra.md` — operation semantics and laws
- `lifetimes.md` — custody, borrowing, claims and policy
- `embedding.md` — direct runtime driving and hosts
- `resource-authoring.md` — trusted primitive facility implementation
- `internals.md` — kernel representation and execution
