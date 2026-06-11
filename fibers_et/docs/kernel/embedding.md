# Stepping, waits and host integration

`fibers` is intended to be embedded.  The runtime does not need to own the host
main loop.

## Driver shape

A host may drive the runtime to quiescence:

```lua
rt:run()
```

or step it with a bounded algebra budget:

```lua
local status = rt:step({ max_work = 100 })
```

A `pending` status means no transaction has committed yet and the runtime is
waiting for more work, more budget, or a host condition.

## Typed wait interests

Wait interests are not partial commits.  They are typed descriptions of future
conditions under which search may become productive.

The public wait kinds are centred on the base kit:

```text
source    host signal/queue/readiness occurrence
time      clock source deadline
cell      cell predicate or modify_when may become true
region    region ownership/lifetime state may change
```

The runtime records the latest waits:

```lua
local waits = rt:pending_wait_summary()
```

The summary is intended for host adapters.  It avoids forcing the transaction
runtime to own timers, fd polling, GUI events or game-engine callbacks.

## Sources

`fibers.Source` is the public way to expose host events.  A source may be a
clock, a host signal, a queue source, or a readiness source.

```lua
local clock = fibers.Source.clock('clock')
local signal, feed = rt:signal('signal')
local fd_read, fd_feed = rt:readiness_source(fd, 'read')
```

Source consumers do not mutate. Host-side changes use runtime-bound producers,
for example `feed:set(value)` or `fd_feed:set_ready(true)`, so bounded search
state is invalidated by construction. `rt:arrive(source, ...)` is the lower-level
host boundary used by those producers.

## Time

Clock sources use host time:

```lua
local now = 0
local rt = fibers.Runtime.new({ host = { now = function() return now end } })
local clock = fibers.Source.clock('clock')

rt:spawn_raw(function()
  rt:perform(clock:at_op(10))
end)
```

If the deadline has not arrived, the operation reports a typed time wait.  When
the host clock reaches the deadline, the host calls `step` or `run` again.

## Readiness

Readiness sources are not POSIX-specific.  A key can be an fd, socket, GUI
handle, LuaTeX callback token, game-engine event source, or any other
host-defined readiness object.

Readiness enters through a runtime-bound producer capability.  This keeps
bounded stepping correct by construction: the same call that changes readiness
also invalidates any in-progress search cursor.

```lua
local readable, readable_feed = rt:readiness_source(fd, 'read')

-- From host driver code, when the handle becomes readable:
readable_feed:set_ready(true)

-- From host driver code, when the readiness condition is consumed or reset:
readable_feed:clear_ready('read')
```

There is deliberately no dynamic `host.ready` or `source_ready` probe.  A host
that observes readiness must feed that fact into the runtime explicitly.

## Effects and host callbacks

Effects are committed runtime obligations.  Built-in effects include:

```text
wake   a committed state change may make a wait productive
spawn  start a fibre after admission commits
```

A host may observe wake publication with:

```lua
fibers.Runtime.new({
  host = {
    wake = function(payload, rt, log)
      -- register or nudge host-side readiness
    end,
  },
})
```

The current guarantee remains in-process.  If a host needs crash recovery or
external exactly-once delivery, the effect should install a durable obligation
or idempotency key, and delivery should be retried outside the transaction.

## Protected calls

Embedded hosts should not need global `pcall`/`xpcall` monkey-patching.  Code running inside a fibre can use `fibers.pcall` and `fibers.xpcall` when the protected function may perform an operation and therefore suspend.

On Lua 5.1-style hosts these functions use a coroutine-backed implementation.  On hosts whose native protected calls already support yielding, the native path is used unless fallback mode is forced for testing.

Runtime transaction phases are still non-suspending.  The runtime recognises protected-call child coroutines as belonging to the currently resumed fibre, but `perform` remains forbidden from driver, search, resource and commit phases.
