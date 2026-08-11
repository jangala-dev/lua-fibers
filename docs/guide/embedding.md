# Embedding

This guide explains how to drive Fibers from a bounded or foreign host. It is application-facing: kernel and package architecture are covered in [Packages and ports](../design/packages-and-ports.md).

`fibers` does not require control of the process event loop. An application may use the root lifecycle prelude or drive a `Runtime` directly.

Embedding code imports driver interfaces separately from the lifecycle prelude:

```lua
local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Sleep = require('fibers.sleep')
local Stream = require('fibers.io.stream')
local AutoIO = require('fibers.io.auto')
local ManualHost = require('fibers.embed.manual')
```


## Creating and driving a runtime

```lua
local fibers = require('fibers')

local host = ManualHost.new() -- deterministic time and readiness
local rt = Runtime.new({ host = host })

rt:spawn_raw(function()
  -- embedded root fiber
end)
```

The driver methods are:

```lua
rt:run(opts)
rt:step({ max_work = n })
```

`Runtime:run` starts ready fibers and searches all pending focuses until at least one transaction commits or no further immediate progress is found.

`Runtime:step` applies a bounded search allowance. The execution-frontier kernel retains the same semantic position through a Lua coroutine, including its rollback trail, witness cursors and branch loops. A later call resumes the exact proof while its observed locations, resource generations and participant buckets remain unchanged. A relevant admission, commit or external delivery invalidates only affected sessions.

Current status shapes are:

```text
{ tag = 'found', ... }
    at least one transaction committed

{ tag = 'pending', kind = 'wakeup', interests = {...} }
    host-actionable waits may make progress

{ tag = 'pending', kind = 'budget', interests_incomplete = true, ... }
    bounded search has not completed

{ tag = 'pending', kind = 'started', ... }
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

The kernel also accepts three optional hard limits:

```lua
local rt = Runtime.new({
  search_total_limit = 100000, -- reduction rounds in one proof session
  search_depth_limit = 256,   -- live branch depth
  search_trail_limit = 500000, -- live rollback-journal entries
})
```

A hard limit returns the same budget status with `reason` set to `search_total_limit`, `search_depth_limit` or `search_trail_limit`. The incomplete session is discarded because repeating it with the same hard limit cannot make progress; a later driver call starts a fresh proof. These limits do not establish `Retry` and therefore cannot enable a fallback.

The trail limit is checked between reduction rounds. One deterministic reduction may therefore take the live journal modestly beyond the configured value before the runtime reports the limit. Hard limits are disabled by default.

## Root lifecycle

`fibers.run` constructs a Runtime and root Scope, then drives the selected Host:

```lua
fibers.run(function()
  fibers.perform(Sleep.sleep_op(1))
end, {
  host = AutoIO.default(),
})
```

`fibers.run` delegates host integration to `fibers.embed.external.drive`. The embedding loop repeatedly calls `Runtime:run`; when the runtime reports actionable pending interests, it calls the host's blocking hook and re-enters the runtime after the host reports progress.

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

For each dynamic `choice` occurrence, the evaluator derives a deterministic branch permutation from this seed and replay-visible runtime identities. It does not consume `math.random`. Given the same seed, program, request sequence and external inputs, the same evaluator reproduces the traversal.

This is a replay aid, not a fairness or probability contract. A different host delivery order, task/request construction order, solver version or option graph may produce a different execution. Record the seed alongside failure diagnostics.

## Host contract

A host object may provide:

```text
host:now(runtime) -> number
host:block(runtime, interests, status, opts) -> progressed, reason
```

`Runtime:now` calls the host's time function. Time should be monotonic for timer semantics unless the application deliberately supplies another model.

`host:block` may block, poll, register interests or decline them. If it returns no progress, `fibers.embed.external.drive` returns the pending status with the host reason attached; `fibers.try_run` reports that as a checked root-lifecycle failure.

Portable and embedded hosts are selected directly from their semantic owner:

```lua
local PureHost = require('fibers.embed.pure')
local ManualHost = require('fibers.embed.manual')
local Roblox = require('fibers.roblox')

local pure = PureHost.new(opts)
local manual = ManualHost.new(opts)
local app = Roblox.prepare(root, opts)
```

`pure` is time-oriented. `manual` is deterministic and intended for tests and
explicit event-loop integration. Roblox is non-blocking and is driven through
`prepare` or `attach`.

Optional native I/O backends may be imported explicitly or discovered through
`fibers.io.auto`:

```lua
local AutoIO = require('fibers.io.auto')

local host = AutoIO.nixio(opts)
local selected = AutoIO.select('luaposix', opts)
local default = AutoIO.default(opts)
```

`AutoIO.default` tries the supported native implementations and falls back to the
portable time-only host. It does not select manual or engine integrations.
Inspect native availability with:

```lua
for _, item in ipairs(AutoIO.available()) do
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

`Clock` is the time resource. An explicit or default clock provides:

```lua
local clock = Clock.default()
clock:now_op()          -- yields the observed monotonic time
clock:at_op(deadline)   -- waits until an absolute time
clock:after_op(duration) -- relative surface syntax
```

`after_op` is defined algebraically as `now_op():and_then(guard(now -> at_op(now + duration)))`. The observed time is therefore an explicit provisional value. Backtracking and validation do not slide the resulting deadline, while a genuinely new progression may observe a new instant.

Application code may retain the familiar sleep vocabulary over the default clock:

```lua
Sleep.sleep_until_op(deadline)
Sleep.sleep_op(duration)
```

`Sleep` does not expose `now_op`; clock observation belongs to `Clock`.

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

The final host method `block(runtime, interests, status, opts)` owns wait planning and delivery. POSIX-like hosts use the internal `fibers.embed.wait_set` module to group readiness keys and deadlines; embedders may use the same module when implementing a custom host, but automatic I/O selection does not re-export these helpers.

There is no host readiness query during transaction search. External truth enters through feeds so that validation remains meaningful.

## HostHandle, streams and the reactor

`fibers.io.handle` provides the boundary between non-blocking host I/O and the Runtime-local readiness index and reactor.

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
registration identity. The reactor then performs one bounded authoritative `read` or
`write` call in fiber phase.

The read side reserves Flow capacity before calling the host. The write side leases a committed byte prefix before calling the host. These space and data leases preserve backpressure and exact byte custody across irreversible calls.

Readiness remains a hint. A host call may still return `would_block`; the reactor then releases the read-space reservation or retains the write-data lease as appropriate and waits for refreshed readiness.

Direct `read_ready_op()` and `write_ready_op()` use belong at the HostHandle or
host-adapter boundary. Higher-level facilities should consume reactor-owned Flow,
Offer or Completion state instead. The sole built-in facility exception is the
current datagram send path, pending a separate bounded payload-submission and
custody contract.

The small ManualHost provides deterministic time and readiness. In-memory pipe and socket simulation lives in `tests.support.simulated_host`; custom embedders inject final host methods directly.

A custom `HostHandle` supplies:

```text
handle:readiness_key()
handle:read(max)
handle:write(bytes)
handle:shutdown_read(reason)
handle:shutdown_write(reason)
handle:close(reason)
```

The callback set is authoritative for a concrete handle. Do not duplicate it in a `features` table: `supports(name)` follows the presence of the corresponding callback, and `close` is mandatory.

Opening a Stream commits its custody and both reactor-registration effects together. If the option loses, no handle is attached and no reactor service starts. Local Stream closure retires both registrations, closes active leases and closes the handle exactly once; `closed_op` observes those domain facts. Complete custody retirement remains the Stream Lifetime's `outcome_op`.

See the [Flow and Stream contract](resources.md#detailed-flow-and-stream-contract) for leases and portable byte semantics, and [I/O design](../design/io.md) for the reactor service model.

## Process capability

A host which advertises `features.process = true` supplies one launch and
process-handle contract:

```text
host:start_process(spec) -> host_process, parent_endpoints | nil, nil, error

host_process:pid()
host_process:open_exit_op(scope)
host_process:exit_op()
host_process:signal(signal, target)
host_process:close(reason)
```

A fully process-honest `start_process` completes an exec-error handshake.
Returning a process after fork alone is insufficient: working-directory,
environment, process-group, standard-stream and exec setup must either succeed
or produce a structured launch error. Partial child processes must be killed
and reaped before the failed call returns.

A host may expose a narrower, explicit process contract when its native API lacks a required primitive. Capabilities are sparse: presence means support and absence means unsupported. The Nixio host therefore reports `process_close_fds = "known"` and `process_groups = "session"`; it omits `process_exec_proof` and `process_pass_fds`.

Parent pipe endpoints are non-blocking HostHandles and remain under lexical setup ownership until their Streams adopt them and enter the reactor path. The process handle itself is also audited. Exactly one supervisor has custody of signal decisions and exit observation. `open_exit_op` admits a reactor-owned one-shot completion beneath the process Scope; `exit_op` returns the cached authoritative terminal status once the provider has reaped the process exactly once.

The Linux FFI family uses pidfds where available and timer-polled `waitpid` otherwise. The test-only SimulatedHost provides deterministic process completion and signalling. A host with no usable process contract omits `features.process` and the `start_process` method.

## File capability

A host which advertises `features.file = true` must provide a complete
evented file path. The standard provider selector first asks the host for:

```text
host:file_provider(runtime, opts) -> provider | nil
```

A provider implements `open`, `rename`, `unlink`, `mkdir` and optionally
`mkdir_p`. `open` must honour `exclusive` and `permissions` when supplied. Open
returns a backend implementing `read`, `write`, `seek`, `flush`, `sync` and
`close`. Line framing and other byte contracts are Flow operations above this
provider boundary; providers deal only in byte chunks.

The completion-driven byte contract is deliberately small. `read(count)` returns
a non-empty string, `''` for EOF, or `nil, error`; `write(bytes)` returns a
positive consumed byte count or `nil, error`. A regular-file backend must not
use `would_block`: the provider is responsible for suspending its private driver
until the completion is authoritative. Partial writes are permitted and are
settled through the same Flow lease law used by the socket Reactor. Backend
methods may suspend their Fibers driver, but must not execute potentially
blocking filesystem calls on the runtime thread.

Linux FFI hosts return a shared `io_uring` provider when the ring probe passes.
If a host has process support and supplies no native provider, Fibers selects the helper-process provider. The test-only SimulatedHost supplies an in-memory provider. There is no synchronous bootstrap fallback.

Capability detail fields are:

```text
file_backend    "io_uring", "worker", "memory" or nil
file_io_uring   a usable ring was detected
file_aio_detected  the POSIX AIO symbol set was detected
```

`file_aio_detected` does not imply that AIO is the selected complete backend; path and
lifetime operations still require `io_uring` or worker isolation.

## Effects and host work

Hosts are reached through typed effects and reactor/provider contracts after the
selected world has committed. Effect preparation must remain pure; irreversible
host work belongs to effect discharge or to a running Lifetime body.

A host callback must not call `perform` re-entrantly. External completions are
published through the Runtime's feed and reactor mechanisms and become facts for
a later proof step.

The runtime guarantee is in-process. Crash durability requires durable external
state and idempotent integration.

## Protected calls and runtime phases

Applications may use `fibers.pcall` and `fibers.xpcall`. Reusable libraries
may import `fibers.protected` without depending on the root lifecycle façade.
Both forms provide yieldable protection on Lua 5.1 as well as later versions.

`perform` is forbidden from:

```text
host callbacks
driver callbacks
search callbacks
transition and witness callbacks
effect preparation and discharge
```

Only fiber-phase code may suspend through `perform`.

## Native host bindings

A native family is one file. It defines a table of raw clock, descriptor, poll,
network, resolver and process calls, then passes that table directly to the
shared POSIX-like host implementation:

```lua
local Posix = require('fibers.io.posix')

local binding = {
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

return Posix.define(binding)
```

The binding performs native calls, native value conversion and native error
extraction. `fibers.io.posix` constructs the final host directly and owns
Fibers handles, stale-safe readiness identities, socket and datagram policy,
resolver deduplication, process endpoints and capability reporting. There is no
intermediate adapter or provider-description layer.

Native operation identity, the value submitted to the poller and an optional
numeric descriptor are separate. Nixio may therefore use an opaque object for
I/O and polling while LuaPOSIX and FFI use integers; operations which require a
numeric descriptor test for it explicitly.

ManualHost, PureHost and RobloxHost construct the final host protocol directly. ManualHost is deliberately small: deterministic time, readiness and optional injected final methods. The richer in-memory operating-system simulation is test support. Timer and readiness planning remain in `fibers.embed.wait_set`.

## Host acceptance checklist

A host should be tested for:

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

## I/O lifecycle qualification

Host integration is qualified through executable lifecycle and provider contracts rather than a public reactor snapshot. The internal test instrumentation checks that handles retire, registrations disappear, custody is respected and stale registration identities are ignored. Those counters and indexes are implementation details, not application observability.

Hosts must declare stream-socket family support separately through
`socket_ipv4`, `socket_ipv6` and `socket_unix`. Unsupported capabilities should
return structured errors; they should not be inferred from the presence of a
poller or descriptor backend.
