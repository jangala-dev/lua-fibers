# Atom kit

`fibers` is organised around a small public atom kit.  These nouns are the low-level public machinery.  Compound facilities such as `Scope` and policies are built above them.  The kernel resource protocol, wait interests and typed effect machinery remain implementation and extension tools rather than a second user model.

```text
Op       possible transaction
Scalar   replacement transactional fact and ordered state-machine update
Rendezvous  synchronous rendezvous
Index    ordered transactional stock
Counter  bounded numeric transactional stock
Keyed    per-key transactional map/set
Lease    compatibility-based transactional lease table
Source   external, host or time occurrence made transactional
Region   transactional ownership boundary
Effect   after-commit runtime obligation
```

The rule of thumb is:

```text
Scalar facts and small state machines go in Scalar.
Ordered stock goes in Index.
Numeric stock goes in Counter.
Keyed facts go in Keyed.
Compatibility leases go in Lease.
Meetings go through Rendezvous values.
External occurrences arrive through Sources.
Regions record ownership. Compound task and scope facilities build on Regions.
Committed obligations are Effects.
Everything composes as an Op.
```

## Op

An `Op` is immutable transaction syntax.  It can be stored, passed around,
chosen between, sequenced, combined and performed by a fibre.

```lua
local op = fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1.0):map(function() return nil, 'timeout' end)
)
```

## Scalar

A `Scalar` is replacement transactional state. Reads and writes are journalled, and `expect_op(value)` is a premise demand over the projected scalar value.  It is used for gate-like facts such as pool open/closed state, where a sibling close must constrain an acquire in the same world.

```lua
local counter = fibers.Scalar.new(0)

local inc = counter:read_op():and_then(function(n)
  return counter:write_op(n + 1):map(function() return n + 1 end)
end)

local function wait_until(scalar, pred)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then return fibers.always(s.value) end
      return scalar:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

local ready = wait_until(counter, function(n) return n >= 10 end)
```

For a single atomic state-machine transition, define a typed transition and run
it with `transition_op`.  A transition callback receives the projected scalar
value and a payload, then returns the new value followed by the operation result
values.  Transition premises are resolved one at a time in ordered
proof-contribution frames, so contending transitions are serialised without
exposing provisional values to `and_then`. Use `Effect`, not scalar transitions,
for committed external work.

```lua
local s = fibers.Scalar.new(0)

local inc = fibers.Scalar.transition {
  name = 'example.inc',
  mode = 'update',
  validate = function(payload)
    if payload.by ~= nil and type(payload.by) ~= 'number' then error('by must be a number', 2) end
  end,
  step = function(n, payload)
    local next = n + (payload.by or 1)
    return next, next
  end,
}

local op = s:transition_op(inc, { by = 1 })
```

For related transitions, group them with `Scalar.kind`:

```lua
local CounterState = fibers.Scalar.kind {
  name = 'example.counter_state',
  transitions = {
    inc = {
      mode = 'update',
      step = function(n, payload) return n + payload.by, n + payload.by end,
    },
  },
}

s:transition_op(CounterState:transition('inc'), { by = 1 })
```

`validate(payload)` is optional and runs before the operation is built.
`unsafe_update_op` and `unsafe_select_op` remain low-level building blocks for
transition authors; ordinary facilities should use typed transitions.

## Rendezvous

A `Rendezvous` is a synchronous rendezvous point.

```lua
ch:put_op('hello')
ch:get_op()
```

A send and receive commit only when the runtime finds a compatible world.


## Index, Counter, Keyed and Lease

`Index`, `Counter`, `Keyed` and `Lease` are the merge-aware atoms used to
build larger transactional structures without writing a custom kernel resource.
They all follow the same `all`/`tensor` law:

```text
all may coordinate allocation from existing shared stock and sibling constraints.
tensor may additionally let one lane supply another lane.
```

`Index` is ordered stock.  A pop opens a premise; the solver allocates a
concrete entry before any `and_then` callback runs.

```lua
local ix = fibers.Index.new({ { key = 'a', rank = 1, value = 'A' } })
ix:insert_op('b', 2, 'B')
ix:append_op('C')
ix:pop_first_op()
ix:pop_last_op()
```

`Counter` is bounded numeric stock. `take_op` opens a premise; `give_op`/`add_op` are positive supply. `adjust_op` is the signed expert operation.

```lua
local slots = fibers.Counter.new({ initial = 10, min = 0, max = 10 })
slots:take_op(1)
slots:give_op(1)
```

`Keyed` is a per-key map/set atom.  Presence-demanding operations such as
`get_op`, `remove_present_op` and `put_absent_op` open premises.

```lua
local items = fibers.Keyed.new({})
items:put_op('k', 'v')
items:get_op('k')
items:put_absent_op('k', 'v')
items:remove_present_op('k')
```

`Lease` is a compatibility table for leases and reservations.

```lua
local leases = fibers.Lease.new({ read = { read = true }, write = {} })
leases:acquire_op('file', 'read', 'alice')
leases:release_op('file', 'alice')
```

The first compound facilities built from these atoms are deliberately ordinary Lua:

```text
Task          = Region + Scalar + Effect
Queue         = Index + Counter
Channel       = Rendezvous when capacity is 0; Queue when capacity is positive
PriorityQueue = Index + Counter
Pulse         = Scalar
WaitGroup     = Scalar
Mailbox       = Scalar + Queue/Rendezvous
Pool          = Index + Keyed + Lease + Scalar + Effect
                (items in Keyed, idle membership in Index, active leases in Lease)
RateLimiter   = Scalar
Flow          = Scalar endpoints + Scalar reservoir
```



## Channel, Pulse, WaitGroup and Mailbox

`Channel` is a small facade rather than a new resource. `Channel.new(0)` returns
a `Rendezvous`; `Channel.new(n)` for positive `n` returns a bounded `Queue` with
capacity `n`.  The returned value exposes the underlying primitive's `_op`
methods.

```lua
local unbuffered = fibers.Channel.new(0)
local buffered = fibers.Channel.new(16)
```

## Pulse, WaitGroup and Mailbox

`Pulse` is a versioned broadcast notifier built as a small Scalar state machine.
Signals coalesce by incrementing a logical version; `changed_op(last_seen)`
commits when the version has advanced or the pulse has been closed.

`WaitGroup` is also a Scalar state machine.  Its `wait_op()` is a zero-count
select transition, so a sibling `done_op()` can satisfy it under `tensor` but not
as positive supply hidden behind `all`.

`Mailbox` is a closeable compound facility.  Metadata such as counted sender
handles, close reason and dropped count live in a Scalar.  Buffered mailboxes use
`Queue`; capacity-zero mailboxes use `Rendezvous`.  It deliberately exposes `_op`
methods only.

```lua
local pulse = fibers.Pulse.new()
pulse:signal_op()
pulse:changed_op(0)

local wg = fibers.WaitGroup.new()
wg:add_op(1)
wg:done_op()
wg:wait_op()

local tx, rx = fibers.Mailbox.new(16, { full = 'block' })
tx:send_op('message')
rx:recv_op()
tx:close_op('done')
```

## Flow

`Flow` is a scalar-state-machine byte reservoir. Endpoint gates are `Scalar`
values and the reservoir is a `Scalar` containing ordered bytes and active
leases. Reads use typed Scalar select transitions, so writes hand off to reads under
`tensor` but not under `all`.

```lua
local flow = fibers.Flow.new({ capacity = 65536 })
flow:inlet():write_op("abc")
flow:outlet():read_op(3)
flow:outlet():lease_op(4096, "pump")
```

## RateLimiter

`RateLimiter` is a token-bucket facility built on typed Scalar transitions.  The
bucket state is one scalar state machine containing `{ tokens, last }`; refill
and token consumption happen in named ordered transitions, so parallel acquires
serialise without double-refilling.

```lua
local limiter = fibers.RateLimiter.new({ capacity = 10, rate = 5 })
limiter:acquire_op(1)
limiter:try_acquire_op(1)
limiter:available_op()
```

## Source

A `Source` brings an external, host or time occurrence into the transaction
algebra.

```lua
local rt = fibers.Runtime.current()
local signal, feed = rt:signal('signal')
local clock = fibers.Source.clock('clock')
local readiness, readiness_feed = rt:readiness(fd)

signal:wait_op()
fibers.sleep_op(0.25)      -- facility over a clock Source
clock:at_op(deadline)      -- low-level absolute clock-source wait
readiness:readable_op()
feed:set('changed')
readiness_feed:readable()
```

Source consumers do not mutate. External facts enter through runtime-bound
producer capabilities, or through `rt:arrive(source, ...)`. Signals are latched
facts observed with `wait_op`; queues are occurrence streams consumed
transactionally with `next_op`.

## Region

A `Region` is the generic ownership boundary. Practical code will usually use the `Scope` facility, which is built over Region, Task, Source and Effect. `Task` itself is a standard compound facility: it is admitted to a Region and started after the admitting transaction commits, but it is no longer part of the atom kit.

```lua
local scope = fibers.Scope.new('main')

local task = fibers.perform(scope:spawn_op(function()
  return 7
end))

local value = fibers.perform(task:await_op())
```

`Region` remains the sparse ownership primitive: admit, move, seal and release. `Scope` is the more ergonomic compound facility. Nursery and supervisor-style APIs are policies over scopes, not special cases inside the option algebra.

## Effect

An `Effect` is a typed transaction effect: runtime-owned work that is
discharged iff the selected world commits.

```lua
local op = fibers.after_commit(effect)
```

Effects are not participant continuations.  They are prepared and discharged by
the runtime after resource commit and before selected participants resume.

## Ownership claims and settlement

A `Region` records typed ownership. Each owned record carries a settlement
protocol.  Region itself does not know about shutdown, closure, item disposal,
stream draining or task cancellation; it only knows how to admit owned records,
move live roots, claim a live root subtree for a purpose, and resolve a valid
claim.

```text
live subtree
  -> claim subtree for purpose
  -> driver performs settlement protocols
  -> resolve claim with discharge, fail or restore
```

For ordinary handles the settlement protocol may be inert.  Tasks usually use an
interrupt-then-join protocol.  Stream pump tasks use a join-only protocol,
because the stream's terminal flow state is what makes the pump exit.  Host
streams are admitted as owned compounds whose children include their flows,
endpoints and pump tasks.

Advanced users can construct ownership explicitly with `fibers.Region.Owned`.  A custom
settlement protocol is just a function returning an `Op`:

```lua
fibers.Region.Owned.item(handle, function(ctx, record, claim)
  return handle:shutdown_op(claim.reason):wrap(function()
    fibers.mask(function() fibers.perform(handle:closed_op()) end)
    return true
  end)
end)
```

The protocol is ordinary algebra: it may sequence, wait, emit effects and use
post-commit wraps.  The `Region` owns the exactly-once claim and final discharge.
Ordinary user code requests retirement through a facility such as `Scope`; the
scope claims the subtree, runs settlement protocols masked, and performs the
final `discharge_claim` option.  Public record and subtree snapshots expose diagnostic
claim metadata such as `claim_id`, but not the authority object itself.

If a settlement protocol fails, the claim is not rolled back.  The affected
records remain owned in `failed` phase and the boundary report carries the
failure.  See `docs/facilities/settlement.md`.

Ownership records responsibility, movement and settlement.  Safe resource
facilities should also treat live ownership as runtime authority, so stale Lua
handles fail after their scope retires them.

