# API reference

This document records the public surface of Fibers. It is organised by module and intended for lookup rather than first learning.

For practical explanations, see [Options](guide/options.md), [Lifetimes](guide/lifetimes.md), [Resources](guide/resources.md) and [I/O](guide/io.md).

## Conventions


The exact v1 module contract is recorded in [`packages/public_modules.lua`](../packages/public_modules.lua). A source module absent from that allow-list is an implementation detail even when it is importable from a repository checkout. There are no aggregate `fibers.io`, `fibers.embed` or `fibers.dns` modules; import the required explicit module.

### Strict v1 contracts

V1 public and trusted-extension boundaries are deliberately exact:

- `nil` is the only omission/default sentinel unless a documented value such as `timeout = false` has explicit semantics;
- public option tables are closed records and reject unknown keys;
- numbers and booleans are not coerced from strings, truthy values or fractional integers;
- compatibility aliases are not retained alongside canonical names;
- host/provider, facility and effect callbacks have one authoritative contract; concrete handle/provider support is defined by its required method set, while supplementary capability metadata remains explicit;
- cleanup failures are accounted for and are not silently discarded.

Conversion remains appropriate only at explicit external boundaries, for example parsing `/etc/resolv.conf`, decoding a child-process protocol record, or converting native ABI values into Lua values. Those adapters normalise external representation; they do not broaden the v1 Lua contract.

Canonical examples include `process_group = "new"` rather than `new_session`, `family_hint` on unresolved name endpoints rather than `family`, and the explicit Stream methods `read_some`, `read_exactly`, `read_until`, `read_line` and `read_all` rather than Lua-file-style `read(...)` aliases.


### Direct and `_op` forms

Where a method `x_op(...)` returns an option, a corresponding direct method `x(...)` performs it in the current fiber:

```lua
object:x(...)
-- equivalent to
fibers.perform(object:x_op(...))
```

The reference lists both forms where they are central. Direct twins preserve values, errors, cancellation and lifetime effects.

### Suspension

An option-producing function never suspends merely by constructing the option. A direct method or `fibers.perform` may suspend if the selected world cannot yet commit.

### Labels

Supported identity-bearing values expose:

```lua
value:label()          -- current label or nil
value:label(string)    -- set and return value
value:label(nil)       -- clear and return value
```

Labels are diagnostic metadata and do not affect semantics.

Options expose:

```lua
option:label(non_empty_string) -> new_option
```

The original option remains unchanged.

## `fibers`

```lua
local fibers = require('fibers')
```

### `fibers.run(fn [, opts])`

Creates and drives a Runtime and root scope. Calls `fn(scope)`. Returns body values after retained custody has resolved, or raises structured failure.

Common options include `host`, Runtime options and root-scope label or Closure settings supported by the selected host.

### `fibers.try_run(fn [, opts]) -> ScopeResult`

Checked form of `run`.

### `fibers.perform(option) -> ...`

Selects and commits one coherent result. Requires a current running fiber.

### `fibers.spawn(fn [, opts]) -> Task`

Spawns a structured Task in the current scope.

### `fibers.scope([opts,] fn) -> ...`

Creates a nested scope, calls `fn(scope)` and raises on boundary failure.

### `fibers.try_scope([opts,] fn) -> ScopeResult`

Checked form of `scope`.

### `fibers.without_suspension(fn, ...) -> ...`

Runs `fn` under a dynamic contract prohibiting an actual scheduling hand-off. Immediate `perform` calls remain permitted.

### `fibers.mask(fn, ...) -> ...`

Defers ordinary cancellation observation within the dynamic region.

### `fibers.pcall(fn, ...)`

Protected call preserving Fibers cancellation and Runtime error semantics.

### `fibers.xpcall(fn, handler, ...)`

Protected call with an error handler.

### `fibers.current_runtime() -> Runtime | nil`

Returns the current Runtime.

### `fibers.current_scope() -> Scope | nil`

Returns the current scope.

### `fibers.now() -> number`

Returns the current Runtime time.

## `fibers.op`

```lua
local Op = require('fibers.op')
```

### `Op.always(...) -> Op`

An immediately available result preserving exact multiple values.

### `Op.never() -> Op`

An option with no possible result.

### `Op.choice(...) -> Op`

Unordered permission among alternative occurrences. Accepts varargs or a single array table.

### `Op.named_choice(entries) -> Op`

Accepts a string-keyed table of options. Returns the selected key followed by branch values.

### `Op.each(...) -> Op`

Independent conjunction. Returns an array of packed rows.

### `Op.named_each(entries) -> Op`

String-keyed independent conjunction. Returns a keyed result table with original rows in `_rows`.

### `Op.together(...) -> Op`

Interacting conjunction. Returns an array of packed rows.

### `Op.named_together(entries) -> Op`

String-keyed interacting conjunction. Returns a keyed result table with original rows in `_rows`.

### `Op.guard(fn) -> Op`

Constructs a dynamic residual option. Beneath `and_then`, `fn` receives provisional prefix values.

### `Op.emit(effect) -> Op`

Selects a typed committed effect obligation.

### `option:map(fn) -> Op`

Transforms provisional results. `fn` must be replayable and non-yielding.

### `option:and_then(next_option) -> Op`

Sequences both options in one transaction.

### `option:or_else(fallback) -> Op`

Uses the preferred option if it can happen now; otherwise considers the fallback.

### `option:wrap(fn) -> Op`

Runs `fn` in the selected participant after commitment.

### `option:on_defeat(effect) -> Op`

Attaches a typed defeat obligation to this dynamic occurrence.

### `option:label(label) -> Op`

Returns a newly labelled option.

### `Op.is_op(value) -> boolean`

Tests whether a value is an Op.

## `fibers.runtime`

```lua
local Runtime = require('fibers.runtime')
```

### `Runtime.new([opts]) -> Runtime`

Creates a Runtime without driving it.

### `Runtime:step([opts]) -> status`

Advances the Runtime by one bounded driver step.

### `Runtime:run([opts]) -> status`

Drives until the Runtime reaches a terminal or host-wait state according to the selected host.

### `Runtime:perform(option [, opts]) -> ...`

Performs from the currently resumed Runtime fiber.

### `Runtime:spawn_raw(fn)`

Starts an unstructured fiber.

### `Runtime:now() -> number`

Returns Runtime time.

### `Runtime:failed() -> boolean`

Reports whether a fatal Runtime failure has occurred.

### `Runtime.current() -> Runtime | nil`

Returns the current Runtime.

### `Runtime.cancelled(reason [, token])`

Constructs a cancellation error.

### `Runtime.is_cancelled(value) -> boolean`

Tests a cancellation error.

## `fibers.channel`

```lua
local channel = require('fibers.channel')
```

### `channel.new([capacity]) -> Channel`

Creates a synchronous channel when capacity is absent or zero, a bounded FIFO for a positive capacity, or an unbounded FIFO for `math.huge`.

### `Channel:put_op(value) -> Op`
### `Channel:get_op() -> Op`
### `Channel:put(value)`
### `Channel:get() -> value`

## `fibers.sleep`

```lua
local Sleep = require('fibers.sleep')
```

### `Sleep.sleep_op(delay) -> Op`
### `Sleep.sleep_until_op(deadline) -> Op`
### `Sleep.sleep(delay)`
### `Sleep.sleep_until(deadline)`

## `fibers.task`

### `Task.is(value) -> boolean`
### `Task:lifetime() -> Lifetime`
### `Task:body_result_op() -> Op`
### `Task:outcome_op() -> Op`
### `Task:await() -> ...`
### `Task:request_cancel_op([reason]) -> Op`
### `Task:request_cancel([reason])`
### `Task:cancel_requested_op() -> Op`
### `Task:label([value])`

`Task.Exit` provides `returned`, `failed`, `cancelled`, `is`, `status` and `unwrap` helpers for body exits.

## `fibers.scope`

```lua
local Scope = require('fibers.scope')
```

### `Scope.new([opts]) -> Scope`

Creates a scope capability. Application code normally receives scopes from `run`, `scope` or a Lifetime view.

### `Scope:parent_scope() -> Scope | nil`
### `Scope:lifetime() -> Lifetime`
### `Scope:perform(option) -> ...`
### `Scope:mask(fn, ...) -> ...`
### `Scope:spawn_op(fn [, opts]) -> Op`
### `Scope:spawn(fn [, opts]) -> Task`
### `Scope:admit_op(value) -> Op`
### `Scope:move_op(item, target) -> Op`
### `Scope:offer_op(item, target [, terms]) -> Op`
### `Scope:accept_op([filter]) -> Op`
### `Scope:grant_op(item, holder, rights [, opts]) -> Op`
### `Scope:can_op(item, right) -> Op`
### `Scope:start_retire_op(item [, reason]) -> Op`
### `Scope:retire(item [, reason]) -> item`
### `Scope:request_cancel_op([reason]) -> Op`
### `Scope:cancel_requested_op() -> Op`
### `Scope:try_run(fn) -> ScopeResult`
### `Scope:run(fn) -> ...`
### `Scope:label([value])`

## Scope results and reports

```lua
local Scope = require('fibers.scope')
local Result = Scope.Result
local Report = Scope.Report
```

### `Result.is(value) -> boolean`
### `result.ok -> boolean`
### `result:unpack() -> ... | nil, reason, report`
### `result:raise() -> ...`
### `result:tostring() -> string`
### `result:done_outcome() -> table`

A failed result may expose `primary`, `report`, `closure_failures` and `closure_failure`.

### `Report.is(value) -> boolean`
### `report:append(error) -> report`
### `report:tostring() -> string`

Reports may contain body exits, child exits, child failures, secondary failures and Closure failures.

## `fibers.closure`

```lua
local Closure = require('fibers.closure')
```

### `Closure.running() -> closure_protocol`
### `Closure.protocol(spec) -> closure_protocol`
### `Closure.none() -> closure_protocol`
### `Closure.request_then_wait(request_fn, finished_fn [, opts]) -> closure_protocol`

Local protocols describe how one Lifetime discharges its own continuing
consequence. `running()` is the standard protocol for a running execution.

### `Closure.nursery([opts]) -> supervision_policy`

Child failure fails the Scope boundary and requests closure of siblings.

### `Closure.supervisor([opts]) -> supervision_policy`
### `Closure.policy(value) -> supervision_policy`

Scope policy is separate from local shutdown. It reacts to body, cancellation
and child outcomes, and is supplied to Scope/task construction rather than
being packaged into a Lifetime protocol.

### `Closure.start_retire_op(scope, item [, reason]) -> Op`

Transactionally acquires structural closure responsibility and emits the
committed start of a closure process. The returned `Closure.Process` is a
transactional result: `map`, `and_then`, `each`, `together` and `or_else` may
continue to compose with the initiation transaction. If that complete world
loses, no closure driver starts.

### `Closure.Process.is(value) -> boolean`
### `process:success_op() -> Op`
### `process:failure_op() -> Op`
### `process:result_op() -> Op`
### `process:success() -> item`
### `process:failure() -> Closure.Failure`
### `process:result() -> boolean, item | Closure.Failure`

A `Closure.Process` is the committed structural closure already in progress.
Its observation Options are fresh transactions. `result_op()` returns
`true, item` on successful discharge or `false, failure` when responsibility
is retained after a closure fault.

### `Closure.Failure.is(value) -> boolean`
### `failure:inspect() -> table`
### `failure:inspect_op() -> Op`
### `failure:retry_op() -> Op`
### `failure:force_op() -> Op`
### `failure:retry() -> Closure.Process`
### `failure:force() -> Closure.Process`

Recovery authority is linear. `retry_op()` and `force_op()` transactionally
consume it, restart the retained CloseClaim and emit the committed closure
driver. They return a fresh `Closure.Process` for the recovery attempt; observe its
result in a later transaction.

## `fibers.lifetime`

```lua
local Lifetime = require('fibers.lifetime')
```

### `Lifetime.new([opts]) -> Lifetime`
### `Lifetime.define(value [, opts]) -> value`
### `Lifetime.is(value) -> boolean`
### `Lifetime.of(value) -> Lifetime | nil`
### `Lifetime.require(value [, level]) -> Lifetime`

Lifetime nodes support:

```lua
life:label([value])
life:retired_op()
life:request_close_op([reason])
life:request_cancel_op([reason])
life:cancel_requested_op()
life:close_requested_op()
life:outcome_op()
```

Most applications should use Tasks and Scopes rather than constructing Lifetimes directly.

Live managed state has no generic snapshot API or raw epoch. Observe the domain fact needed by the program through a focused Option such as `closed_op`, `close_requested_op`, `cancel_requested_op`, `outcome_op` or a resource-specific operation. Task execution completion is deliberately task-specific and is observed through `Task:body_result_op()`; a generic Lifetime exposes only its complete terminal outcome. Friendly direct methods are performing twins of those Options; they are not a second observation path. Internal versions and epochs are not public semantics. Trusted facility-authoring and host-provider interfaces are implementation boundaries, not application observation APIs.

## `fibers.grant`

### `Grant.is(value) -> boolean`
### `grant:has_right(right) -> boolean`
### `grant:retired_op() -> Op`
### `grant:retired() -> Grant`

Grants are normally created through `Scope:grant_op`.

## `fibers.resource.cell`

```lua
local Cell = require('fibers.resource.cell')
```

### `Cell.new(value) -> Cell`
### `cell:read_op() -> Op`
### `cell:expect_op(value) -> Op`
### `cell:write_op(value) -> Op`
### `cell:select_op(select) -> Op`
### `cell:wait_until_op(predicate) -> Op`
### `cell:match_op(matcher) -> Op`

Direct twins exist for `read`, `expect`, `write`, `wait_until` and `match`.

Cell contents are available only through these operations. `.value` and `.version` are not part of the public semantics. Cell values use the single public managed-value domain: scalars and plain finite value trees. Fibers captures table values on entry and exposes independent table values on exit; unsupported identity-bearing or aliased structures are rejected immediately. `expect_op` uses structural managed-value equality. See [Resources](guide/resources.md#managed-values).

## `fibers.resource.counter`

```lua
local Counter = require('fibers.resource.counter')
```

### `Counter.new(initial) -> Counter`
### `Counter.bounded(capacity) -> Counter`
### `Counter.range(initial, minimum, maximum) -> Counter`
### `counter:read_op() -> Op`
### `counter:adjust_op(amount) -> Op`
### `counter:add_op(amount) -> Op`
### `counter:bump_op() -> Op`
### `counter:give_op([amount]) -> Op`
### `counter:take_op([amount]) -> Op`
### `counter:at_least_op(value) -> Op`
### `counter:at_most_op(value) -> Op`
### `counter:equal_op(value) -> Op`
### `counter:zero_op() -> Op`

Direct twins exist for all listed operations. Counter contents are available only through these operations; `.value` and `.version` are not part of the public semantics.

## `fibers.semaphore`

### `Semaphore.new(capacity) -> Semaphore`
### `semaphore:acquire_op([amount]) -> Op`
### `semaphore:release_op([amount]) -> Op`
### `semaphore:available_op() -> Op`
### `semaphore:acquire([amount])`
### `semaphore:release([amount])`
### `semaphore:available() -> number`

## `fibers.pulse`

### `Pulse.new([initial]) -> Pulse`
### `pulse:version_op() -> Op`
### `pulse:why_op() -> Op`
### `pulse:is_closed_op() -> Op`
### `pulse:signal_op() -> Op`
### `pulse:close_op([reason]) -> Op`
### `pulse:changed_op(last_seen) -> Op`
### `pulse:next_op() -> Op`

Direct twins exist for all listed operations.

## `fibers.latch`

### `Latch.new() -> Latch`
### `latch:set_op(value) -> Op`
### `latch:get_op() -> Op`
### `latch:is_set_op() -> Op`

Direct twins are `set`, `get` and `is_set`.

## `fibers.mailbox`

```lua
local tx, rx = Mailbox.new([capacity])
local tx, rx = Mailbox.reject_newest(capacity)
local tx, rx = Mailbox.drop_oldest(capacity)
```

### Sender endpoint

```lua
tx:send_op(value)
tx:clone_op()
tx:close_op([reason])
tx:why_op()
tx:dropped_op()
```

Direct twins are `send`, `clone`, `close`, `why` and `dropped`.

### Receiver endpoint

```lua
rx:recv_op()
rx:why_op()
rx:dropped_op()
```

Direct twins are `recv`, `why` and `dropped`.

Labelling either endpoint labels the shared Mailbox facility.

## `fibers.resource.flow`

```lua
local Flow = require('fibers.resource.flow')
local flow = Flow.new(limit)
local inlet = flow:inlet()
local outlet = flow:outlet()
```

### Inlet

```lua
inlet:write_op(value)
inlet:write_all_op(value)
inlet:write_some_op(value)
inlet:reserve_some_op(n [, holder, meta])
inlet:flush_op()
inlet:close_op()
inlet:closed_op()
inlet:fail_op(error)
```

### Outlet

```lua
outlet:read_some_op(n)
outlet:read_exactly_op(n)
outlet:peek_exactly_op(n)
outlet:read_until_op(separator [, opts])
outlet:read_line_op([opts])
outlet:read_all_op(opts)
outlet:drop_op(n)
outlet:splice_to_op(inlet, n)
outlet:lease_some_op(n [, holder, meta])
outlet:close_op([reason])
outlet:closed_op()
outlet:fail_op(error)
```

### Flow

```lua
flow:abort_op()
flow:closed_op()
```

The `_op` byte methods each describe one transactional byte decision, and every
listed operation has the ordinary direct twin which performs it. A finite Flow
capacity is an initial working high-water mark rather than preallocated storage.
Exact bounded reads (`read_exactly_op`, `peek_exactly_op`, delimiter reads and
`read_all_op`) may ask the runtime to raise that high-water mark while they wait;
no bytes are consumed until the read transaction commits. `read_all_op` requires a
finite `opts.max` and grows far enough to distinguish EOF within the bound from
`Flow.Error.TOO_LARGE` without consuming an oversized input. The finite constructor
limit also remains the payload ceiling for ordinary `write_op`; adaptive storage
growth does not silently widen that operation policy. `write_all_op` explicitly asks
for elastic whole-payload admission and may transactionally enlarge the working
high-water mark to the size of one known payload. Growth changes only the logical
high-water mark: the Rope allocates storage for bytes actually retained.

## `fibers.stream`

### `Stream.compose(read_flow, write_flow [, opts]) -> Stream`
### `Stream.memory_pair([opts]) -> stream_a, stream_b`
### `Stream.merge_lines_op(streams [, opts]) -> Op`
### `Stream.merge_lines(streams [, opts])`

A Stream supports:

```lua
stream:reader()
stream:writer()
stream:is_readable()
stream:is_writable()
stream:is_duplex()
stream:local_address()
stream:peer_address()
stream:read_some_op(n)
stream:read_exactly_op(n)
stream:read_until_op(separator [, opts])
stream:read_line_op([opts])
stream:read_all_op(opts)
stream:write_op(...)
stream:write_all_op(...)
stream:write_some_op(bytes)
stream:flush_op()
stream:shutdown_read_op([reason])
stream:shutdown_write_op([reason])
stream:abort_write_op([reason])
stream:request_close_op([reason])
stream:request_abort_op([reason])
stream:closed_op()
stream:close([reason])
stream:abort([reason])
```

`read_exactly`, bounded `read_all` and `write_all` are exact direct/Option pairs.
Their Flow-backed Options may use elastic working capacity as described above while
remaining one transaction. `write_op` is deliberately bounded by the Flow
constructor's write-unit limit; `write_all_op` is the explicit elastic whole-write
form. `request_close`/
`request_close_op`, `request_abort`/`request_abort_op` and `closed`/`closed_op` are
also exact pairs. `close()` and `abort()` are causal convenience protocols and
therefore deliberately have no `_op` twin.

## `fibers.file`

Host-backed file operations require a compatible Runtime host.

### Static operations

```lua
File.submit_pipe_op([opts])
File.submit_open_op(path [, mode, opts])
File.submit_tmpfile_op([opts])
File.submit_read_all_op(path [, opts])
File.submit_write_all_op(path, bytes [, opts])
File.submit_rename_op(from, to [, opts])
File.submit_unlink_op(path [, opts])
File.submit_mkdir_op(path [, opts])
File.submit_mkdir_p_op(path [, opts])
```

Each submission Option has an exact direct twin without `_op`, for example `File.submit_open()`. The higher-level `pipe`, `open`, `tmpfile`, `read_all`, `write_all`, `rename`, `unlink`, `mkdir` and `mkdir_p` methods are causal convenience procedures: they submit work and then observe its readiness or result, so they deliberately have no `_op` twin.

Detached forms are typed by what has been admitted. Static path work such as `submit_read_all_op` returns a `File.Job`; `submit_open_op` returns the admitted `RegularFile`; RegularFile control submissions return a `File.Command`. Data-plane reads and writes have no Request layer: they transact directly on the file's Flow byte plane.

### RegularFile

```lua
file:ready_op()
file:read_op(count)
file:read_some_op(count)
file:read_exactly_op(count)
file:read_all_op([opts])
file:write_op(bytes)
file:write_all_op(bytes)
file:write_some_op(bytes)
file:read_line_op([keep])
file:submit_seek_op([whence, offset])
file:submit_flush_op()
file:submit_rename_op(path)
file:submit_sync_op([opts])
file:request_close_op([reason])
file:closed_op()
file:close([reason])
file:filename()
```

`read_op`/`read_some_op`, `read_exactly_op`, bounded `read_all_op`, `write_op`,
`write_all_op` and `write_some_op` each describe one Flow-backed byte decision.
`read_exactly`, `read_all` and `write_all` are their exact performing twins. The
file driver continues to fill or drain the Flow while a whole-byte Option waits;
elastic high-water growth allows a bounded exact fact to exceed the initial
read-ahead/write capacity without splitting the participant transaction. A
`read_all` maximum is finite (16 MiB by default for RegularFile convenience) and
oversize failure does not consume the buffered file. Control submissions return a
`File.Command`; `command:result_op()` observes the corresponding host-side barrier
after admission. Direct `seek`, `flush`, `rename` and `sync` submit and then wait
for that result, so they have no misleading `_op` twin. `request_close`/
`request_close_op` and `closed`/`closed_op` are exact pairs; `close()` performs the
complete causal close protocol.

## `fibers.process`

```lua
local process = require('fibers.process')
```

### Commands

```lua
process.command(...)
process.shell(script [, opts])
command:spec()
command:argv()
command:with_cwd(path)
command:with_env(values [, opts])
command:with_stdin(value)
command:with_stdout(value)
command:with_stderr(value)
command:with_shutdown(value)
command:with_process_group(value)
command:launch_op([opts])
command:launch([opts])
command:start([opts])
```

Commands are immutable reusable descriptions.

### Process

```lua
proc:lifetime()
proc:pid_op()
proc:pid()
proc:argv()
proc:stdin_op()
proc:stdin()
proc:stdout_op()
proc:stdout()
proc:stderr_op()
proc:stderr()
proc:launch_result_op()
proc:result_op()
proc:submit_signal_op(signal [, target])
proc:submit_terminate_op()
proc:submit_kill_op()
proc:request_close_op([reason])
proc:closed_op()
proc:signal(signal [, target])
proc:terminate()
proc:kill()
proc:communicate([opts])
proc:close([reason])
```

The process PID and standard streams become available when launch commits. Their direct methods perform the corresponding focused Options; they are not immediate object-field reads. Signal submissions return a request whose `result_op()` observes the supervisor-owned host action. The `signal`, `terminate` and `kill` conveniences submit and wait, so they deliberately have no `_op` twin.

### Helpers

```lua
process.succeeded(status) -> boolean
process.describe_status(status) -> string
```

## `fibers.socket`

### Address helpers

Socket address values are provided through `fibers.net.address` and convenience constructors exposed by the socket module where documented.

### Listening

```lua
Socket.submit_listen_op(address [, opts])
Socket.submit_listen_ipv4_op(host, port [, opts])
Socket.submit_listen_ipv6_op(host, port [, opts])
Socket.submit_listen_inet_op(host, port [, opts])
Socket.submit_listen_unix_op(path [, opts])
```

Exact direct twins omit `_op`. Submission admits and starts the Listener; `Socket.listen(...)` and its family-specific convenience forms additionally wait for Listener readiness and therefore have no `_op` twin.

A Listener supports:

```lua
listener:accept_op([target_scope])
listener:accept([target_scope])
listener:local_address_op()
listener:local_address()
listener:request_close_op([reason])
listener:request_close([reason])
listener:closed_op()
listener:close([reason])
listener:closed()
```

### Resolving

```lua
Socket.resolve_op(endpoint [, opts])
Socket.resolve_name_op(host, service [, opts])
Socket.dns_resolver([opts])
```

A resolver Query supports family-specific and aggregate result, failure, state, close and closed options with corresponding direct methods.

### Dialling

```lua
Socket.dial_op(endpoint [, opts])
Socket.connect(endpoint [, opts])
```

A Dial supports:

```lua
dial:connected_op([target_scope])
dial:failed_op()
dial:result_op([target_scope])
dial:report_op()
dial:request_close_op([reason])
dial:request_close([reason])
dial:closed_op()
dial:connect([target_scope])
dial:result([target_scope])
```

### Datagrams

```lua
Socket.submit_udp_op(address [, opts])
Socket.submit_udp_ipv4_op(host, port [, opts])
Socket.submit_udp_ipv6_op(host, port [, opts])
```

Exact direct submission twins omit `_op`. `Socket.udp(...)` and its family-specific convenience forms submit the Datagram and then wait for readiness, so they have no `_op` twin.

A Datagram supports:

```lua
udp:send_to_op(data, address)
udp:receive_from_op([opts])
udp:flush_op()
udp:request_close_op([reason])
udp:request_close([reason])
udp:closed_op()
udp:close([reason])
udp:local_address_op()
udp:local_address()
```

Exact direct twins exist for readiness, local address, send, receive, flush, request-close and closed. `close()` is the complete causal close procedure and has no `_op` twin.

## `fibers.effect`

```lua
local Effect = require('fibers.effect')
```

### `Effect.kind(spec) -> EffectKind`
### `Effect.of(kind, payload) -> Effect`
### `Effect.is_kind(value) -> boolean`
### `Effect.is_effect(value) -> boolean`
### `Effect.reject([reason]) -> EffectRejection`
### `Effect.is_rejection(value) -> boolean`
### `Effect.rejection_reason(value) -> any`
### `Effect.interrupt(token [, reason]) -> Effect`

Most applications should use higher-level facilities. See [Committed effects](advanced/extending.md#committed-effects).

## Embedding modules

```lua
local Application = require('fibers.embed.application')
local Queue = require('fibers.embed.queue')
```

### `Application.new(fn [, opts]) -> Application`

Prepares an application for bounded host-driven execution.

### `Queue.new([opts]) -> host`

Creates the standard queue-backed embedding host.

The Application and host protocols are described in [Embedding](guide/embedding.md).

## `fibers.roblox`

```lua
local Roblox = require('fibers.roblox')
```

### `Roblox.events(signal [, opts]) -> Subscription`
### `Roblox.latest(signal [, opts]) -> Subscription`
### `Roblox.pulse(signal [, opts]) -> Subscription`
### `Roblox.new_host([opts]) -> host`
### `Roblox.prepare(fn [, opts]) -> Application`
### `Roblox.attach(fn [, opts]) -> Application`
### `Roblox.try_run(fn [, opts]) -> ScopeResult`
### `Roblox.run(fn [, opts]) -> ...`
### `Roblox.bind_to_close([scope_or_opts, opts])`

Subscriptions support:

```lua
subscription:next_op()
subscription:retired_op()
subscription:start_retire_op([reason])
subscription:retire([reason])
```

`start_retire_op` has the same two-stage structural Closure semantics as the
Scope operation and returns a `Closure.Process` when performed.

See [Fibers for Roblox](guide/roblox.md).

## Advanced public modules

The following modules are public but intended mainly for facility authors, embedders or constrained ports:

- `fibers.resource.authoring`
- `fibers.resource.machine`
- `fibers.resource.keyed`
- `fibers.resource.index`
- `fibers.resource.claim_set`
- `fibers.embed.external`
- `fibers.embed.manual`
- `fibers.embed.queue`
- the exact I/O and embedding modules listed in `packages/public_modules.lua`

Their contracts are documented in [Extending Fibers](advanced/extending.md), [Embedding](guide/embedding.md), [Flow and Stream contract](guide/resources.md#detailed-flow-and-stream-contract) and the design documents. Modules under `fibers.internal.*` are not public API.
