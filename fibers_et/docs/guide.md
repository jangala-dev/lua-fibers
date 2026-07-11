# Programming guide

This guide covers the ordinary application-facing use of `fibers`. The semantic definitions are in `algebra.md`; ownership and settlement are in `lifetimes.md`.

## Runtime, scope and fibres

Most programmes begin with `fibers.run`:

```lua
local fibers = require('fibers')

fibers.run(function()
  -- root scope body
end)
```

`fibers.run` creates a runtime, a root scope and a standalone runner. The body may spawn structured tasks and perform operations.

```lua
fibers.run(function()
  local task = fibers.spawn(function()
    return 'done'
  end, 'worker')

  assert(fibers.perform(task:await_op()) == 'done')
end)
```

`fibers.spawn` requires a current scope and is governed by that scope's policy. The default nursery rejects `fibers.spawn_raw`; deliberately unstructured work must be enabled explicitly with `policy.nursery({ allow_unstructured = true })`, or started through the low-level `Runtime:spawn_raw` embedding API.

Nested scopes use `fibers.scope`:

```lua
fibers.scope(function(scope)
  local task = fibers.spawn(function()
    return 7
  end)
  assert(fibers.perform(task:await_op()) == 7)
end)
```

The raising forms `run` and `scope` return body values or raise after accounting for the boundary. `try_run` and `try_scope` return structured result and report values instead.

## Operations

An `Op` is an immutable description of a possible transaction. Constructing an operation does not perform it.

```lua
local op = fibers.always(42)
assert(fibers.perform(op) == 42)
```

The common combinators are:

```lua
op:map(function(value) ... end)
op:and_then(function(value) return another_op end)
op:or_else(fallback_op)
op:wrap(function(committed_value) ... end)
op:on_defeat(effect)
```

`map` and `and_then` run during speculative search and must not perform external side effects. `wrap` runs inside the resumed participant after commit and may perform another operation.

### Choice

`choice` is eager competition:

```lua
local value, err = fibers.perform(fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1):map(function()
    return nil, 'timeout'
  end)
))
```

A selected branch commits; entered competing branches may produce typed defeat obligations. Temporary search failure, retry and bounded-search incompleteness are not defeat.

### Residual fallback

`or_else` is not priority choice. It opens the fallback only after the primary has returned a valid `Retry` proof.

```lua
local op = cache:get_op(key):or_else(fetch_default_op(key))
```

An `Unknown` result from bounded search never enables fallback.

### Products

`all` combines independent lanes in one commit. Sibling lanes may constrain allocation but cannot positively supply one another.

```lua
local a, b = fibers.perform(fibers.all({
  left:take_op(1),
  right:take_op(1),
}))
```

`tensor` allows interacting lanes to close internal rendezvous and transactional handoffs:

```lua
fibers.perform(fibers.tensor({
  slots:give_op(1),
  slots:take_op(1),
}))
```

Use `all` when several requirements must be independently satisfied from the current world. Use `tensor` when sibling operations intentionally provide facts or communication to one another.

## Rendezvous and channels

A `Rendezvous` is an unbuffered synchronous meeting:

```lua
local ch = fibers.Rendezvous.new('jobs')

local send = ch:put_op({ id = 1 })
local receive = ch:get_op()
```

The send and receive commit together.

`Channel` is a convenience façade:

```lua
local unbuffered = fibers.Channel.new(0)  -- Rendezvous
local buffered = fibers.Channel.new(16)  -- bounded Queue
```

Both expose `put_op` and `get_op` through their underlying implementation.

## Transactional state

### Scalar

Use `Scalar` for one replaceable fact or a small state machine:

```lua
local state = fibers.Scalar.new({ open = true, count = 0 }, 'state')

local op = state:read_op():and_then(function(old)
  if not old.open then return fibers.never() end
  return state:write_op({ open = true, count = old.count + 1 })
end)
```

For a single ordered state transition, prefer typed transitions:

```lua
local Increment = fibers.Scalar.transition {
  name = 'counter.increment',
  mode = 'update',
  validate = function(payload)
    assert(type(payload.by) == 'number', 'by must be a number')
  end,
  step = function(value, payload)
    local next_value = value + payload.by
    return next_value, next_value
  end,
}

local counter = fibers.Scalar.new(0)
local next_value = fibers.perform(counter:transition_op(Increment, { by = 1 }))
```

Transition callbacks are trusted transactional code. They must be non-yielding and free of external side effects.

### Standard allocation resources

`Index`, `Counter`, `Keyed` and `Lease` cover common allocation problems:

```lua
local index = fibers.Index.new()
index:insert_op('a', 10, 'value')
index:pop_first_op()

local permits = fibers.Counter.new({ initial = 4, min = 0, max = 4 })
permits:take_op(1)
permits:give_op(1)

local table_state = fibers.Keyed.new()
table_state:put_op('key', 'value')
table_state:get_op('key')

local leases = fibers.Lease.new({ read = { read = true }, write = {} })
leases:acquire_op('document', 'read', 'worker-1')
leases:release_op('document', 'worker-1')
```

These resources participate in the `all`/`tensor` distinction. Under `tensor`, positive sibling supply may satisfy a premise in the same committed world.

## Compound coordination facilities

The following facilities are library compounds rather than new kernel primitives:

```text
Queue          Index + Counter
PriorityQueue  Index + Counter
Pulse          Scalar
WaitGroup      Scalar
Mailbox        Scalar + Queue or Rendezvous
Pool           Index + Keyed + Lease + Scalar + Effect
RateLimiter    Scalar state machine
Task           Region + Scalar + Effect
Scope          Region + Task + policy
Flow           transactional byte reservoir and endpoints
Stream         two Flows plus optional host pumps
```

Typical use remains operation-oriented:

```lua
local wg = fibers.WaitGroup.new()
fibers.perform(wg:add_op(1))
fibers.perform(wg:done_op())
fibers.perform(wg:wait_op())

local tx, rx = fibers.Mailbox.new(16)
fibers.perform(tx:send_op('message'))
assert(fibers.perform(rx:recv_op()) == 'message')
```

## External facts and time

`Signal`, `EventQueue`, `Clock` and `Readiness` are ordinary resources whose state may be updated through a runtime-bound feed.

```lua
fibers.run(function()
  local rt = fibers.current_runtime()
  local signal, feed = rt:signal('shutdown')

  fibers.spawn(function()
    feed:set('requested')
  end)

  assert(fibers.perform(signal:wait_op()) == 'requested')
end)
```

A `Signal` is latched. An `EventQueue` stores externally delivered occurrences which are consumed transactionally. A `Clock` observes host time. `Readiness` records host readiness levels.

Application code normally uses `sleep_op` rather than constructing clock deadlines directly:

```lua
fibers.perform(fibers.sleep_op(0.25))
```

Relative sleep fixes its absolute deadline once for the current perform attempt.

## Effects and outcome obligations

An effect is typed runtime work entailed by a committed world:

```lua
local op = fibers.after_commit(effect)
```

Effects are prepared before resource commit and discharged after resource journals are installed but before selected participants resume. Losing worlds discharge nothing.

`op:on_defeat(effect)` attaches a typed obligation to an entered operation occurrence which loses to a committed competitor. Retry, fallback, validation conflict and incomplete search are not defeat.

The guarantee is in-process and per commit. It is not crash-durable exactly-once delivery.

## Scopes, custody and settlement

Most lifetime-bearing objects should be created inside a scope. A scope takes custody and accounts for the object when its boundary closes.

```lua
fibers.scope(function(scope)
  local task = scope:spawn(function()
    return 'ok'
  end)

  assert(fibers.perform(task:await_op()) == 'ok')
end)
```

The ordinary operations are:

```text
admit     take custody
move      transfer custody atomically
borrow    grant temporary authority without moving custody
seal      stop accepting new custody
claim     take exclusive settlement authority
resolve   discharge, fail or restore a claim
```

See `lifetimes.md` before directly using `Region`, claims, custom settlement or borrowing.

## Flows and streams

A `Flow` is a unidirectional transactional byte reservoir. Its inlet writes bytes and its outlet reads them:

```lua
local flow = fibers.Flow.new({ capacity = 4096 })
local inlet = flow:inlet()
local outlet = flow:outlet()

fibers.perform(inlet:write_op('abc'))
assert(fibers.perform(outlet:read_op(3)) == 'abc')
```

A `Stream` is two flows arranged bidirectionally:

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
assert(fibers.perform(b:reader():read_line_op()) == 'hello')
```

Important properties are:

```text
losing writes append nothing
losing reads consume nothing
read_exactly waits without consuming a partial prefix
peek observes without freeing bytes
splice moves bytes in one committed world
retained bytes, including active leases, consume capacity
producer closure yields EOF after retained bytes drain
consumer closure settles retained bytes as failure
```

`write_op(bytes)` is all-or-nothing for one commit. `write_some_op` commits one non-empty prefix. Large multi-commit programmes should be explicit rather than presented as one transaction.

Host-backed streams use a backend and read/write pump tasks:

```lua
local stream = fibers.perform(
  fibers.Stream.open_backend_in_op(scope:raw_region(), backend, {
    name = 'connection',
  })
)
```

Opening is transactional: if the open operation loses, no pump starts. Use `stream:reader()` and `stream:writer()` as the stable authority-bearing endpoints. The backend contract and readiness rules are described in `embedding.md`.

## Errors and protected calls

Inside fibres, use `fibers.pcall` and `fibers.xpcall` when protected code may perform operations. This is required for portable behaviour on Lua 5.1, where native protected calls cannot reliably cross coroutine suspension.

Resource protocol code, effect preparation and commit internals are trusted and non-yielding. An escaping error from those layers is a fatal runtime integrity failure.

## Further reading

- `algebra.md` defines the operation semantics and laws.
- `lifetimes.md` covers scopes, ownership, authority and settlement.
- `embedding.md` covers hosts, feeds, readiness and bounded stepping.
- `resource-authoring.md` is for implementing new resource kinds.
- `internals.md` describes the source tree and runtime pipeline.
