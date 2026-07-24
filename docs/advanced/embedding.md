# Embedding and host integration

`fibers` does not require ownership of the process event loop. An application may use the root lifecycle prelude or drive a `Runtime` directly.

Embedding code imports driver interfaces separately from the lifecycle prelude:

```lua
local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Sleep = require('fibers.sleep')
local Stream = require('fibers.stream')
local Host = require('fibers.host')
```


## Creating and driving a runtime

```lua
local fibers = require('fibers')

local host = Host.manual()
local rt = Runtime.new({ host = host })

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

`Runtime:step` applies a bounded search allowance. The production ledger machine retains an incomplete search and resumes its exact alternative stack on a later call while the observed frontier and committed dependencies remain unchanged. A relevant admission, commit or external delivery invalidates the retained session. The reference evaluator continues to restart bounded searches.

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

A budget-pending status is optional `Unknown`, not semantic `Retry`, and cannot enable `or_else`.

### Search budgets and safety limits

`search_limit` remains the resumable work quantum used by an unbounded driver call and defaults to one million reduction rounds. `Runtime:step({ max_work = n })` supplies a smaller quantum for that call. Exhausting a quantum returns:

```lua
{ tag = 'pending', kind = 'budget', reason = 'search_quantum', ... }
```

The production ledger machine also accepts three optional hard limits:

```lua
local rt = Runtime.new({
  search_total_limit = 100000, -- reduction rounds in one proof session
  search_depth_limit = 256,   -- live branch depth
  search_trail_limit = 500000, -- live rollback-journal entries
})
```

A hard limit returns the same budget status with `reason` set to `search_total_limit`, `search_depth_limit` or `search_trail_limit`. The incomplete session is discarded because repeating it with the same hard limit cannot make progress; a later driver call starts a fresh proof. These limits do not establish `Retry` and therefore cannot enable a fallback.

The trail limit is checked between reduction rounds. One deterministic reduction may therefore take the live journal modestly beyond the configured value before the runtime reports the limit. Hard limits are disabled by default and currently apply to the production ledger machine, not the repository reference evaluator.

## Root lifecycle

`fibers.run` constructs a Runtime and root Scope, then drives the selected Host:

```lua
fibers.run(function()
  fibers.perform(Sleep.sleep_op(1))
end, {
  host = Host.default(),
})
```

`fibers.run` delegates host integration to `Runtime:drive`. The driver repeatedly calls `Runtime:run`; when the runtime reports actionable pending interests, it calls the host's blocking hook and re-enters the runtime after the host reports progress.

An embedding which already owns an event loop should normally drive `Runtime:run` or `Runtime:step` itself.

The Roblox profile packages that pattern as a checked root application:

```lua
local app = require('fibers.roblox').prepare(root_fn)
local status = app:advance({ horizon = host_now + turn_budget })
```

A host horizon is an outer scheduling boundary. Exhausting it retains runtime
progress for a later call and does not establish Retry. `Roblox.attach` merely
adds event- or phase-driven scheduling above the same non-blocking interface.

## Reproducible unordered choice

`Runtime.new` accepts a `choice_seed`:

```lua
local rt = Runtime.new({
  host = host,
  choice_seed = 17,
})
```

For each dynamic `choice` occurrence, the evaluator derives a deterministic branch permutation from this seed and replay-visible runtime identities. It does not consume `math.random`. Given the same seed, programme, request sequence and external inputs, the same evaluator reproduces the traversal.

This is a replay aid, not a fairness or probability contract. A different host delivery order, task/request construction order, solver version or option graph may produce a different execution. Record the seed alongside failure diagnostics.

## Host contract

A host object may provide:

```text
host:now(runtime) -> number
host:block(runtime, interests, status, opts) -> progressed, reason
```

`Runtime:now` calls the host's time function. Time should be monotonic for timer semantics unless the application deliberately supplies another model.

`host:block` may block, poll, register interests or decline them. If it returns no progress, `Runtime:drive` returns the pending status with the host reason attached; `fibers.try_run` reports that as a checked root-lifecycle failure.

Built-in host constructors are:

```lua
host.pure(opts)
host.manual(opts)
host.roblox(opts)       -- explicit embedded boundary; does not block
host.luajit_linux(opts)
host.cffi_linux(opts)
host.luaposix(opts)
host.nixio(opts)
host.select(name, opts)
host.default(opts)
```

`pure` is portable and time-oriented. `manual` is deterministic and intended for tests and explicit event-loop integration. `roblox` is non-blocking and is used through `fibers.roblox.prepare` or `fibers.roblox.attach`; it is deliberately excluded from `Host.default`, which serves the standalone `Runtime:drive` path. Native hosts are optional and expose support checks in their implementation modules.

Inspect availability with:

```lua
for _, item in ipairs(host.available()) do
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

Consumer options are ordinary transactions:

```lua
signal:wait_op()
events:next_op()
readiness:readable_op()
readiness:writable_op()
```

Producer or host code uses the bound feed:

```lua
signal_feed:set('requested')
event_feed:set({ kind = 'message', value = 1 })
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
Sleep.sleep_until_op(deadline)
Sleep.sleep_op(duration)
```

A relative sleep fixes its absolute deadline once per perform attempt. Backtracking and validation refresh do not slide the deadline.

The host flow is:

```text
clock option is refuted under now < deadline
runtime reports a timer interest
host waits or arranges a wake
host time advances
embedding re-enters run or step
clock option becomes ready
```

Clock negative checks are pull-validated against current host time. A matured deadline therefore invalidates a stale fallback without external feed mutation.

## Readiness

Readiness keys are host-defined tokens: file descriptors, sockets, GUI handles, game-engine objects or similar values.

Readiness is a level hint. It is not proof that a subsequent non-blocking I/O call will succeed. The call may still return `would_block`; the host or handle must then clear or refresh the readiness level before waiting again.

Helpers include:

```lua
local waits = host.readiness_waits(status.interests)

for _, interest in ipairs(waits) do
  poller:register(interest.readiness_key, interest.mode, interest)
end

-- after polling
host.deliver_readiness(rt, interest)
```

or:

```lua
host.deliver_ready(rt, status.interests, function(key, mode, interest)
  return poller:is_ready(key, mode)
end)
```

There is no host readiness query during transaction search. External truth enters through feeds so that validation remains meaningful.

## HostHandle, streams and the reactor

`host.Handle` provides the boundary between non-blocking host I/O and the runtime-owned HostReactor readiness index and HostReactor.

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

Every configured host-backed direction in one Runtime registers with the same
indexed HostReactor readiness index and lazily created HostReactor. Committed Flow changes arm or
disarm registrations; the host delivers only ready registration identities.
Linux epoll events carry a fresh registration epoch rather than a raw
descriptor. The host validates that epoch before delivering the reaction id and
generation. The reactor then performs one bounded authoritative `read` or
`write` call in fibre phase.

The read side reserves Flow capacity before calling the host. The write side leases a committed byte prefix before calling the host. These space and data leases preserve backpressure and exact byte custody across irreversible calls.

Readiness remains a hint. A host call may still return `would_block`; the reactor then releases the read-space reservation or retains the write-data lease as appropriate and waits for refreshed readiness.

The deterministic manual host provides in-memory pipe handles for embedding and tests.

A custom `HostHandle` supplies:

```text
handle:readiness_key()
handle:read(max)
handle:write(bytes)
handle:shutdown_read(reason)
handle:shutdown_write(reason)
handle:close(reason)
```

Opening a Stream commits its ownership and both reactor-registration effects together. If the option loses, no handle is attached and no reactor service starts. Retirement is structural: both registrations retire, active leases settle, the handle closes exactly once, and `closed_op` observes complete Flow and registration closure.

See [`flows-and-streams.md`](flows-and-streams.md) for the Flow lease contracts and reactor service model.

## Process capability

A host which advertises `capabilities.process = true` supplies one launch and
process-handle contract:

```text
host:start_process(spec) -> host_process, parent_endpoints | nil, nil, error

host_process:pid()
host_process:wait_op()
host_process:reap()
host_process:signal(signal, target)
host_process:close(reason)
```

A fully process-honest `start_process` completes an exec-error handshake.
Returning a process after fork alone is insufficient: working-directory,
environment, process-group, standard-stream and exec setup must either succeed
or produce a structured launch error. Partial child processes must be killed
and reaped before the failed call returns.

A compatibility host may expose a narrower, explicit process contract when its
native API lacks a required primitive. Such a host must describe the missing
guarantees through capability fields and reject unsupported command options
rather than silently approximating them. The Nixio host, for example, reports
`process_exec_proof = false`, `process_pass_fds = false`,
`process_close_fds = "known"` and `process_groups = "session"`.

Parent pipe endpoints are non-blocking HostHandles and enter the normal adoption,
Stream and reactor path. The process handle itself is also audited. Exactly one
supervisor owns signal decisions and reaping; `reap` returns `would_block` until
a terminal status is authoritative and returns the same cached status after
successful reaping.

The Linux FFI family uses pidfds where available and timer-polled `waitpid`
otherwise. ManualHost provides deterministic process completion and signalling
for semantic tests. A host with no usable process contract must advertise
`capabilities.process = false` and return `unsupported`.

## File capability

A host which advertises `capabilities.file = true` must provide a complete
evented file path. The standard provider selector first asks the host for:

```text
host:file_provider(runtime, opts) -> provider | nil
```

A provider implements `open`, `rename`, `unlink`, `mkdir` and optionally
`mkdir_p`. `open` must honour `exclusive` and `permissions` when supplied. Open
returns a backend implementing `read`, `read_line`, `write`, `seek`, `flush`,
`sync` and `close`. These methods may suspend their Fibers driver, but must not
execute potentially blocking filesystem calls on the runtime thread.

Linux FFI hosts return a shared `io_uring` provider when the ring probe passes.
If a host has process support and supplies no native provider, Fibers selects
the helper-process provider. ManualHost supplies an in-memory provider. There
is no synchronous bootstrap fallback.

Capability detail fields are:

```text
file_backend    "io_uring", "worker", "memory" or nil
file_io_uring   a usable ring was detected
file_aio_detected  the POSIX AIO symbol set was detected
```

`file_aio_detected` does not imply that AIO is the selected complete backend; path and
lifetime operations still require `io_uring` or worker isolation.

## Effects and host callbacks

Hosts may receive post-commit callbacks such as wake or scope notifications:

```lua
local rt = Runtime.new({
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

## Host provider tables

Every complete host family is assembled from one provider table. The provider
exports native mechanisms and canonical raw results; `fibers.host.native` owns
the Fibers-facing descriptor, readiness, socket, datagram, resolver and process
semantics.

```lua
local Native = require('fibers.host.native')
local provider = {
  name = 'example',
  family = 'example-handles',
  errors = error_classification,
  time = { now = monotonic_now, sleep = sleep },
  fd = raw_descriptor_operations,
  poll = raw_poll_operations,
  net = raw_network_operations,
  resolver = raw_resolver_operations,
  process = raw_process_strategy,
}

return Native.define(provider)
```

Provider functions perform only native calls, address conversion and native
error conversion. They return native values or `nil, errno, message`; they do
not construct Fibers handles, Flows, host errors, sockets or process objects.
The shared implementation owns cancellation, readiness delivery, handle
lifecycle, connection policy, datagram policy, capability reporting and process
endpoints.

The deterministic ManualHost follows the same contract through
`fibers.host.provider.manual`. Adding a host should therefore require one
provider table rather than a family of facility-specific modules.

Timer and readiness planning live in `fibers.host.wait_set`, so provider
construction does not depend on the host selector.

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

## I/O lifecycle inspection

Host adapters can inspect the runtime-owned reactor and the external-resource
audit while diagnosing integration failures:

```lua
local reactor = rt.host_reactor and rt.host_reactor:snapshot()
local audit = rt:io_audit_snapshot({ include_history = true })
```

After an owned I/O tree has settled, contract tests should call:

```lua
rt:assert_io_quiescent('embedding shutdown')
```

This verifies that no HostHandle remains live, no reactor registration remains
indexed and no ownership violation was recorded. Stale readiness deliveries are
ignored by generation and counted in `audit.stats.stale_ready`.

Hosts must declare stream-socket family support separately through
`socket_ipv4`, `socket_ipv6` and `socket_unix`. Unsupported capabilities should
return structured errors; they should not be inferred from the presence of a
poller or descriptor backend.
