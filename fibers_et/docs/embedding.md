# Embedding and host integration

`fibers` does not require ownership of the process event loop. The runtime can be driven directly by an embedding host or through the standalone runner.

## Runtime driving

Create a runtime explicitly for embedding:

```lua
local fibers = require('fibers')

local host = fibers.host.manual()
local rt = fibers.Runtime.new({ host = host })

rt:spawn_raw(function()
  -- embedded root fibre
end, 'root')
```

The main driver methods are:

```lua
rt:run(opts)
rt:step({ max_work = 100 })
```

`run` executes ready work efficiently until it finds a commit, becomes pending, reaches quiescence, or fails. `step` applies a bounded algebra budget and may return an incomplete search cursor through the runtime status.

Typical status tags are:

```text
found       a transaction committed
pending     external interests or further driver work may make progress
quiescent   Retry was established but no actionable host interest remains
idle        no runnable or waiting work
unknown     bounded search has not completed, where exposed by the driver
failed      fatal runtime failure
```

Do not interpret a work-budget exhaustion as semantic `Retry`. `Unknown` must be resumed or reported, not used to enable `or_else`.

## Standalone runner

`fibers.run` uses `fibers.Runner` around a runtime and host:

```lua
fibers.run(function()
  fibers.perform(fibers.sleep_op(1))
end, {
  host = fibers.host.default(),
})
```

The runner repeatedly calls the efficient `Runtime:run` path. When the runtime reports `pending`, it asks the host to block for the current interests and re-enters the runtime after the host reports progress.

An embedding which already owns an event loop should normally call `step` or `run` directly instead.

## Host contract

A host adapter has a narrow contract:

```text
host.now(rt) -> number
host.block(rt, interests, status, opts) -> progressed, reason
```

`now` supplies monotonic or otherwise application-defined runtime time. `block` waits, polls or registers the reported interests. If the host cannot support them, it returns `nil, reason`; the runner then returns the pending status to its caller.

Built-in host families are:

```text
pure          portable time-only host
manual        deterministic test and embedding host
luajit_linux  LuaJIT FFI epoll host
cffi_linux    cffi epoll host for plain Lua
luaposix      luaposix poll host
nixio         nixio poll host
```

They are selected through:

```lua
local host = fibers.host.pure()
local host = fibers.host.manual()
local host = fibers.host.luajit_linux()
local host = fibers.host.cffi_linux()
local host = fibers.host.luaposix()
local host = fibers.host.nixio()
local host = fibers.host.select('luaposix')
local host = fibers.host.default()
```

Optional hosts expose `is_supported()` in their implementation modules and fail clearly when unavailable.

## Retry interests

A `RetryProof` contains validity frontiers and may contain host-actionable interests. Interests are not partial commits and do not justify retry by themselves.

Current interest kinds are centred on:

```text
timer       a clock deadline
external    an externally fed resource condition, including readiness
```

A pending runtime status carries interests:

```lua
local status = rt:run()
if status.tag == 'pending' then
  for _, interest in ipairs(status.interests or {}) do
    -- register with the embedding loop
  end
end
```

Internal resource changes often require no host interest. Their retry proofs are invalidated when another committed transaction changes the observed frontier.

## Runtime-bound external feeds

`Signal`, `EventQueue` and `Readiness` may be paired with an `ExternalFeed` bound to one runtime and resource:

```lua
local signal, signal_feed = rt:signal('shutdown')
local events, event_feed = rt:events('callbacks')
local readiness, readiness_feed = rt:readiness(handle_key)
```

Consumer code performs resource operations:

```lua
signal:wait_op()
events:next_op()
readiness:readable_op()
readiness:writable_op()
```

Host or producer code delivers changes through the feed:

```lua
signal_feed:set('requested')
event_feed:push({ kind = 'message', value = 1 })
readiness_feed:readable()
readiness_feed:writable()
readiness_feed:clear('read')
```

A feed may update only its bound resource through its bound runtime. Delivery invalidates the managed facts on which saved cursors and retry proofs depend before the runtime resumes search.

Low-level hosts may call:

```lua
rt:deliver(interest.feed, mode, value)
```

when the interest already carries the authorised feed.

## Time and sleep

`Clock` is an ordinary resource which observes `rt:now()` through the host. Application code normally uses:

```lua
fibers.sleep_until_op(deadline)
fibers.sleep_op(duration)
```

Relative sleep is guarded so that the absolute deadline is fixed once per perform attempt. Search restart does not slide the deadline forward.

An embedded timer flow is:

```text
sleep operation returns Retry with Timer(deadline)
host records or waits for the deadline
host calls run or step again when time may have advanced
clock evaluation becomes ready once rt:now() >= deadline
```

If the embedding never re-enters the runtime, sleeping fibres do not resume.

## Readiness

Readiness keys are host-defined. They may identify file descriptors, sockets, GUI handles, game-engine objects or other event-loop tokens.

Readiness is a level hint, not proof that I/O will succeed. A non-blocking I/O attempt may still return `would_block` after a readiness operation commits. The driver or handle must then clear or consume the hint before waiting again.

A host typically processes readiness interests as follows:

```lua
for _, interest in ipairs(fibers.host.readiness_waits(status.interests)) do
  poller:register(interest.readiness_key, interest.mode, interest)
end

-- after polling reports ready
fibers.host.deliver_readiness(rt, interest)
```

There is no dynamic `host.ready` query during transaction search. External truth must enter through a feed so that validation remains correct.

## Host handles and streams

A `HostHandle` is the boundary between non-blocking host I/O and transactional stream pumps.

The contract is:

```lua
handle:readiness_key()
handle:read_ready_op()
handle:write_ready_op()
handle:read(max)              -- bytes | nil, err
handle:write(bytes)           -- n | nil, err
handle:shutdown_read(reason)
handle:shutdown_write(reason)
handle:close(reason)
```

Read and write are called only by pump task bodies after the corresponding readiness operation commits. They must not run during transaction search.

A deterministic fake handle is available for tests:

```lua
local host = fibers.host.manual({ auto_advance_time = false })
local handle = fibers.host.Handle.fake({ host = host, key = 'demo' })
local stream = fibers.perform(
  fibers.Stream.open_handle_in_op(scope:raw_region(), handle)
)
```

Useful fake-handle controls include:

```lua
handle:feed_read(bytes)
handle:feed_eof()
handle:block_writes()
handle:unblock_writes()
handle:written()
```

Real host families expose paired descriptor helpers through `host.fd`. A directional pair can be combined for plumbing tests with `fibers.host.Handle.duplex(read_handle, write_handle)`.

A stream backend may also implement the smaller direct contract:

```lua
backend:read_ready_op()
backend:write_ready_op()
backend:read(max)
backend:write(bytes)
backend:shutdown_read(reason)
backend:shutdown_write(reason)
```

The pump owns the irreversible host call; flow journals remain transactional.

## Effects and host callbacks

Effects are runtime obligations which discharge after resource commit. Built-in uses include task spawn, wake, interruption and settlement work.

A host may provide effect-related callbacks, for example:

```lua
local rt = fibers.Runtime.new({
  host = {
    now = function() return os.clock() end,
    wake = function(payload, runtime, log)
      -- nudge or register host-side work
    end,
  },
})
```

The in-process commit guarantee does not imply crash recovery. External delivery should use durable state or idempotency where required.

## Protected calls and phase rules

Use `fibers.pcall` and `fibers.xpcall` inside fibres when protected code may perform an operation. These helpers provide portable yieldable protection on Lua implementations where native `pcall` cannot cross coroutine suspension.

`perform` remains forbidden from:

- driver callbacks;
- transaction search callbacks other than through returned operation structure;
- resource evaluation, resolution, preparation and application;
- effect preparation and discharge;
- arbitrary host callbacks.

## Host acceptance checklist

A host adapter should be tested for:

```text
clock progression and timer wake
read readiness
write readiness
readiness winning against a later timeout
timeout winning against an unready handle
would_block after a readiness hint
feed delivery invalidating saved search
handle deregistration and close
unsupported-interest reporting
serial entry into the runtime driver boundary
```

The host tests under `tests/hosts/` provide the current executable contract.
