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


## Standalone runner and host adapters

Embedding code may call `rt:step(...)` directly.  A standalone application can
instead use the runner layer:

```lua
local fibers = require('fibers')

fibers.run(function()
  fibers.perform(fibers.sleep_op(1))
end)
```

The runner uses `Runtime:run`, not a tight loop over `Runtime:step`.  This keeps
the efficient internal driver path for standalone applications while preserving
`step` for bounded embedding.

A host adapter has a deliberately narrow contract:

```text
host.now(rt) -> number
host:block(rt, wait_summary, status, opts) -> progressed, reason
```

`now` supplies runtime time.  `block` decides whether and how the process should
wait for the reported waits to become productive.  If it cannot support the
waits, it returns `nil, reason`, and the runner returns the pending status to the
caller.

The built-in pure Lua host is intentionally limited:

```lua
local host = require('fibers.host.pure').new()
```

It supports time waits using `os.time` and `os.execute("sleep N")`.  It does not
support polling or arbitrary external events.

Optional Linux hosts implement the same contract:

```lua
local host = require('fibers.host.luajit_linux').new() -- LuaJIT FFI, nanosleep, epoll
local host = require('fibers.host.cffi_linux').new()   -- cffi, nanosleep, epoll
local host = require('fibers.host.nixio').new()  -- nixio, nanosleep, poll
local host = require('fibers.host.luaposix').new()     -- luaposix, nanosleep, poll
```

The built-in host matrix is:

```text
pure          portable fallback; time waits only
nixio   nixio poll backend
luaposix      luaposix poll backend
luajit_linux  LuaJIT FFI epoll backend
cffi_linux    cffi epoll backend for plain Lua
```

These modules are optional.  They are require-able on unsupported interpreters,
but `is_supported()` returns false and `new()` raises a clear error if the
backend is unavailable.

Host integration tests are split by backend and can also be run through the
combined host runner:

```sh
lua tests/hosts/test_all.lua
lua tests/hosts/test_all.lua --filter nixio
lua tests/hosts/test_pure.lua
lua tests/hosts/test_nixio.lua
lua tests/hosts/test_luaposix.lua
lua tests/hosts/test_cffi_linux.lua
luajit tests/hosts/test_luajit_linux.lua
```

The backend tests use skip-on-unavailable probes.  `test_all.lua` is therefore
safe in small environments, while still exercising nixio, luaposix and FFI when they are
installed.  Where the backend is available, the smoke tests use real pipes to
cover read readiness, write readiness, readiness winning over a later timeout,
and timeout winning when a descriptor remains unready.  The general runner
supports the same small harness options:

```sh
lua tests/run_all.lua --list
lua tests/run_all.lua --filter host
lua tests/run_all.lua --verbose
lua tests/run_all.lua --fail-fast
```

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
runtime to own timers, fd polling, GUI events or game-engine callbacks.  For
readiness waits the summary carries the consumer `source` and the original
`readiness_key`, so a host can later call `rt:arrive(source, mode, true)` when
the host object becomes ready.

## Sources

`fibers.Source` is the public way to expose host events.  A source may be a
clock, a host signal, a queue source, or a readiness source.

```lua
local clock = fibers.Source.clock('clock')
local signal, feed = rt:signal('signal')
local fd_read, fd_feed = rt:readiness(fd)
```

Source consumers do not mutate. Host-side changes use runtime-bound producers,
for example `feed:set(value)` or `fd_feed:readable()`, so bounded search
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
local readable, readable_feed = rt:readiness(fd)

-- From host driver code, when the handle becomes readable:
readable_feed:readable()

-- From host driver code, when the readiness condition is consumed or reset:
readable_feed:clear('read')
```

There is deliberately no dynamic `host.ready` or `source_ready` probe.  A host
that observes readiness must feed that fact into the runtime explicitly.

The LuaJIT/Linux FFI host preserves the old `fibers` policy for descriptors that
`epoll` rejects with `EPERM`: they are marked unpollable and treated as
requested readiness while a wait remains registered.  This models descriptors
such as regular files as level-ready.  Synthetic unpollable readiness is not
reported through a separate error readiness mode; the subsequent read or write operation remains
responsible for EOF, `EAGAIN`, or real errors.

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
