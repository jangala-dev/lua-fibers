# Embedding and host integration

`fibers` does not require ownership of the process event loop. An application may use the standalone runner or drive a `Runtime` directly.

## Creating and driving a runtime

```lua
local fibers = require('fibers')

local host = fibers.host.manual()
local rt = fibers.Runtime.new({ host = host })

rt:spawn_raw(function()
  -- embedded root fibre
end, 'root')
```

The driver methods are:

```lua
rt:run(opts)
rt:step({ max_work = n })
```

`Runtime:run` starts ready fibres and searches all pending focuses until at least one transaction commits or no further immediate progress is found.

`Runtime:step` applies a bounded search allowance. The production trail machine retains an incomplete search and resumes its exact alternative stack on a later call while the observed frontier and committed dependencies remain unchanged. A relevant admission, commit or external delivery invalidates the retained session. The reference evaluator continues to restart bounded searches.

Current status shapes are:

```text
{ tag = 'found', ... }
    at least one transaction committed

{ tag = 'pending', kind = 'wakeup', interests = {...} }
    host-actionable waits may make progress

{ tag = 'pending', kind = 'budget', interests_incomplete = true, ... }
    bounded search has not completed

{ tag = 'pending', kind = 'started' | 'no-ready-work', ... }
    more driver work may be required

{ tag = 'quiescent', reason = ... }
    Retry was established but no actionable host interest remains

{ tag = 'idle', ... }
    no live or pending work remains
```

Fatal runtime errors are raised; they are not returned as a `failed` status tag.

A budget-pending status is operational `Unknown`, not semantic `Retry`, and cannot enable `or_else`.

## Standalone runner

`fibers.run` creates a runtime and uses `fibers.Runner`:

```lua
fibers.run(function()
  fibers.perform(fibers.sleep_op(1))
end, {
  host = fibers.host.default(),
})
```

The runner repeatedly calls `Runtime:run`. When the runtime reports actionable pending interests, it calls the host's blocking hook and re-enters the runtime after the host reports progress.

An embedding which already owns an event loop should normally drive `Runtime:run` or `Runtime:step` itself.

## Reproducible unordered choice

`Runtime.new` accepts a `choice_seed`:

```lua
local rt = fibers.Runtime.new({
  host = host,
  choice_seed = 17,
})
```

For each dynamic `choice` occurrence, the evaluator derives a deterministic branch permutation from this seed and replay-visible runtime identities. It does not consume `math.random`. Given the same seed, programme, request sequence and external inputs, the same evaluator reproduces the traversal.

This is a replay aid, not a fairness or probability contract. A different host delivery order, task/request construction order, solver version or operation graph may produce a different execution. Record the seed alongside failure diagnostics.

## Host contract

A host object may provide:

```text
host:now(runtime) -> number
host:block(runtime, interests, status, opts) -> progressed, reason
```

`Runtime:now` calls the host's time function. Time should be monotonic for timer semantics unless the application deliberately supplies another model.

`host:block` may block, poll, register interests or decline them. If it returns no progress, `Runner.run` returns the pending status to its caller with the host reason attached.

Built-in host constructors are:

```lua
fibers.host.pure(opts)
fibers.host.manual(opts)
fibers.host.luajit_linux(opts)
fibers.host.cffi_linux(opts)
fibers.host.luaposix(opts)
fibers.host.nixio(opts)
fibers.host.select(name, opts)
fibers.host.default(opts)
```

`pure` is portable and time-oriented. `manual` is deterministic and intended for tests and explicit event-loop integration. Native hosts are optional and expose support checks in their implementation modules.

Inspect availability with:

```lua
for _, item in ipairs(fibers.host.available()) do
  print(item.name, item.supported, item.reason)
end
```

## Interests and refutation

An uncaught Retry may carry host-actionable interests. Current public interest kinds are:

```text
timer       a deadline
external    a runtime-bound external facility condition
```

A runtime pending status exposes summarised interests:

```lua
local status = rt:run()
if status.tag == 'pending' then
  for _, interest in ipairs(status.interests or {}) do
    -- register with the embedding loop
  end
end
```

Interests are not proof. Exhaustive search and negative checks justify Retry; an interest only describes how one of the relevant facts may change.

Internal location changes often need no host interest. Their recorded versions invalidate stale proofs when another transaction commits.

## Runtime-bound external feeds

Create externally driven facilities through the runtime:

```lua
local signal, signal_feed = rt:signal('shutdown')
local events, event_feed = rt:events('callbacks')
local readiness, readiness_feed = rt:readiness(handle_key, 'handle-readiness')
```

Consumer operations are ordinary transactions:

```lua
signal:wait_op()
events:next_op()
readiness:readable_op()
readiness:writable_op()
```

Producer or host code uses the bound feed:

```lua
signal_feed:set('requested')
event_feed:push({ kind = 'message', value = 1 })
readiness_feed:readable()
readiness_feed:writable()
readiness_feed:clear('read')
```

A feed is cached per runtime/resource pair and cannot be delivered through another runtime.

Low-level delivery is available when an interest already carries the authorised feed:

```lua
rt:deliver(interest.feed, mode, value)
rt:clear_external(interest.feed, mode)
```

Delivery updates only the bound facility, increments its version and runtime epoch, and invalidates saved positive or negative candidates which relied on the old fact.

## Time and sleep

`Clock` observes `Runtime:now()`. Application code usually uses:

```lua
fibers.sleep_until_op(deadline)
fibers.sleep_op(duration)
```

A relative sleep fixes its absolute deadline once per perform attempt. Backtracking and validation refresh do not slide the deadline.

The host flow is:

```text
clock operation is refuted under now < deadline
runtime reports a timer interest
host waits or arranges a wake
host time advances
embedding re-enters run or step
clock operation becomes ready
```

Clock negative checks are pull-validated against current host time. A matured deadline therefore invalidates a stale fallback without external feed mutation.

## Readiness

Readiness keys are host-defined tokens: file descriptors, sockets, GUI handles, game-engine objects or similar values.

Readiness is a level hint. It is not proof that a subsequent non-blocking I/O call will succeed. The call may still return `would_block`; the host or handle must then clear or refresh the readiness level before waiting again.

Helpers include:

```lua
local waits = fibers.host.readiness_waits(status.interests)

for _, interest in ipairs(waits) do
  poller:register(interest.readiness_key, interest.mode, interest)
end

-- after polling
fibers.host.deliver_readiness(rt, interest)
```

or:

```lua
fibers.host.deliver_ready(rt, status.interests, function(key, mode, interest)
  return poller:is_ready(key, mode)
end)
```

There is no host readiness query during transaction search. External truth enters through feeds so that validation remains meaningful.

## HostHandle and streams

`fibers.host.Handle` provides the boundary between non-blocking host I/O and transactional stream pumps.

A handle supplies:

```text
handle:readiness_key()
handle:read_ready_op()
handle:write_ready_op()
handle:read(max)              -> bytes | nil, err
handle:write(bytes)           -> count | nil, err
handle:shutdown_read(reason)
handle:shutdown_write(reason)
handle:close(reason)
```

The irreversible `read` and `write` calls occur in pump fibre bodies only after the matching readiness operation commits. They must not run during proof search.

A deterministic fake handle is available:

```lua
local host = fibers.host.manual({ auto_advance_time = false })
local handle = fibers.host.Handle.fake({ host = host, key = 'demo' })

local stream = fibers.perform(
  fibers.Stream.open_handle_in_op(scope:raw_region(), handle)
)
```

Useful controls include:

```lua
handle:feed_read(bytes)
handle:feed_eof()
handle:block_writes()
handle:unblock_writes()
handle:written()
```

A stream backend may instead implement:

```text
backend:read_ready_op()
backend:write_ready_op()
backend:read(max)
backend:write(bytes)
backend:shutdown_read(reason)
backend:shutdown_write(reason)
```

Flow state remains transactional; host I/O remains owned by pump tasks.

## Effects and host callbacks

Hosts may receive post-commit callbacks such as wake or scope notifications:

```lua
local rt = fibers.Runtime.new({
  host = {
    now = function() return os.clock() end,
    wake = function(payload, runtime)
      -- nudge host-side work
    end,
    scope = function(event, runtime)
      -- observe committed lifetime events
    end,
  },
})
```

These callbacks run after location state has committed. They must not call `perform` re-entrantly.

The runtime guarantee is in-process. Crash durability requires durable external state and idempotent integration.

## Protected calls and runtime phases

Use `fibers.pcall` and `fibers.xpcall` inside fibres when protected code may suspend. They provide yieldable protection on Lua 5.1 as well as later versions.

`perform` is forbidden from:

```text
host callbacks
driver callbacks
search callbacks
transition and witness callbacks
effect preparation and discharge
```

Only fibre-phase code may suspend through `perform`.

## Host acceptance checklist

A host adapter should be tested for:

```text
monotonic clock progression
timer wake
read and write readiness
readiness against timeout competition
would-block after a stale readiness hint
feed delivery invalidating a stale fallback
handle close and deregistration
unsupported-interest reporting
serial entry into the runtime driver boundary
```

The host and readiness tests in `tests/` are the executable contract.
