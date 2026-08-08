# API reference

This document records the public surface of Fibers. It is organised by module and intended for lookup rather than first learning.

For practical explanations, see [Options](guide/options.md), [Lifetimes](guide/lifetimes.md), [Resources](guide/resources.md) and [I/O](guide/io.md).

## Conventions


The exact v1 module contract is recorded in [`packages/public_modules.lua`](../packages/public_modules.lua). A source module absent from that allow-list is an implementation detail even when it is importable from a repository checkout. There are no aggregate `fibers.io`, `fibers.embed` or `fibers.dns` modules; import the required explicit module.


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
### `Task:await_op() -> Op`
### `Task:await() -> ...`
### `Task:request_cancel_op([reason]) -> Op`
### `Task:request_cancel([reason])`
### `Task:cancel_requested_op() -> Op`
### `Task:state_op() -> Op`
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
### `Scope:close_op(item [, reason]) -> Op`
### `Scope:request_cancel_op([reason]) -> Op`
### `Scope:cancel_requested_op() -> Op`
### `Scope:cancellation_op() -> Op`
### `Scope:running_children_op() -> Op`
### `Scope:children_op() -> Op`
### `Scope:custody_op(item) -> Op`
### `Scope:subtree_op(item) -> Op`
### `Scope:inspect_op() -> Op`
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

### `Closure.nursery([opts]) -> closure_contract`

Child failure fails the boundary and closes siblings according to the nursery policy.

### `Closure.supervisor([opts]) -> closure_contract`

Creates an explicit supervisor policy.

### `Closure.running([opts])`
### `Closure.propagation(contract)`
### `Closure.combine(local_contract, propagation)`

Advanced helpers for composing Closure contracts.

## `fibers.lifetime`

```lua
local Lifetime = require('fibers.lifetime')
```

### `Lifetime.new([opts]) -> Lifetime`
### `Lifetime.task(body [, opts]) -> Lifetime`
### `Lifetime.resource(value [, opts]) -> Lifetime`
### `Lifetime.inert(value [, opts]) -> Lifetime`
### `Lifetime.is(value) -> boolean`
### `Lifetime.of(value) -> Lifetime | nil`
### `Lifetime.require(value [, level]) -> Lifetime`
### `Lifetime.define(value, opts) -> value`

Lifetime nodes support:

```lua
life:label([value])
life:current_state()
life:closed_op()
life:request_close_op([reason])
life:request_cancel_op([reason])
life:cancel_requested_op()
life:cancellation_op()
life:body_result_op()
life:outcome_op()
life:inspect_op()
```

Most applications should use Tasks and Scopes rather than constructing Lifetimes directly.

## `fibers.grant`

### `Grant.is(value) -> boolean`
### `grant:has_right(right) -> boolean`
### `grant:closed_op() -> Op`
### `grant:closed() -> Grant`
### `grant:inspect() -> table`

Grants are normally created through `Scope:grant_op`.

## `fibers.resource.cell`

```lua
local Cell = require('fibers.resource.cell')
```

### `Cell.new(value) -> Cell`
### `cell:read_op() -> Op`
### `cell:changed_op(version) -> Op`
### `cell:expect_op(value) -> Op`
### `cell:write_op(value) -> Op`
### `cell:select_op(select) -> Op`
### `cell:wait_until_op(predicate) -> Op`
### `cell:match_op(matcher) -> Op`

Direct twins exist for `read`, `changed`, `expect`, `write`, `wait_until` and `match`.

## `fibers.resource.counter`

```lua
local Counter = require('fibers.resource.counter')
```

### `Counter.new(initial) -> Counter`
### `Counter.bounded(capacity) -> Counter`
### `Counter.range(initial, minimum, maximum) -> Counter`
### `counter:read_op() -> Op`
### `counter:changed_op(version) -> Op`
### `counter:adjust_op(amount) -> Op`
### `counter:add_op(amount) -> Op`
### `counter:bump_op() -> Op`
### `counter:give_op([amount]) -> Op`
### `counter:take_op([amount]) -> Op`
### `counter:at_least_op(value) -> Op`
### `counter:at_most_op(value) -> Op`
### `counter:equal_op(value) -> Op`
### `counter:zero_op() -> Op`

Direct twins exist for all listed operations.

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
outlet:read_all_op([opts])
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

Direct twins exist for the listed public operations.

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
stream:read_all_op([opts])
stream:read_op(spec [, opts])
stream:write_op(...)
stream:write_some_op(bytes)
stream:flush_op()
stream:shutdown_read_op([reason])
stream:shutdown_write_op([reason])
stream:abort_write_op([reason])
stream:close_op([reason])
stream:abort_op([reason])
stream:closed_op()
```

Direct twins exist for the I/O operations.

## `fibers.file`

Host-backed file operations require a compatible Runtime host.

### Static operations

```lua
File.pipe_op([opts])
File.open_op(path [, mode, opts])
File.tmpfile_op([opts])
File.read_all_op(path [, opts])
File.write_all_op(path, bytes [, opts])
File.rename_op(from, to [, opts])
File.unlink_op(path [, opts])
File.mkdir_op(path [, opts])
File.mkdir_p_op(path [, opts])
```

Direct twins are `pipe`, `open`, `tmpfile`, `read_all`, `write_all`, `rename`, `unlink`, `mkdir` and `mkdir_p`.

`submit_*_op` forms return Jobs or Requests where the caller needs selectable completion rather than the final value directly.

### RegularFile

```lua
file:ready_op()
file:read_op(count)
file:read_exactly_op(count)
file:read_all_op([opts])
file:write_op(bytes)
file:write_all_op(bytes)
file:read_line_op([keep])
file:seek_op([whence, offset])
file:flush_op()
file:rename_op(path)
file:sync_op([opts])
file:close_op([reason])
file:closed_op()
file:filename()
```

Direct twins exist for these operations.

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
proc:pid()
proc:argv()
proc:stdin()
proc:stdout()
proc:stderr()
proc:launch_result_op()
proc:result_op()
proc:signal_op(signal [, target])
proc:terminate_op()
proc:kill_op()
proc:request_close_op([reason])
proc:closed_op()
proc:communicate([opts])
proc:close([reason])
```

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
Socket.listen_op(address [, opts])
Socket.listen_ipv4_op(host, port [, opts])
Socket.listen_ipv6_op(host, port [, opts])
Socket.listen_inet_op(host, port [, opts])
Socket.listen_unix_op(path [, opts])
```

Direct twins omit `_op`.

A Listener supports:

```lua
listener:accept_op([target_scope])
listener:accept([target_scope])
listener:local_address()
listener:close_op([reason])
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
dial:close_op([reason])
dial:closed_op()
dial:connect([target_scope])
dial:result([target_scope])
```

### Datagrams

```lua
Socket.udp_op(address [, opts])
Socket.udp_ipv4_op(host, port [, opts])
Socket.udp_ipv6_op(host, port [, opts])
```

A Datagram supports:

```lua
udp:send_to_op(data, address)
udp:receive_from_op([opts])
udp:flush_op()
udp:close_op([reason])
udp:closed_op()
udp:local_address()
```

Direct twins exist for send, receive, flush, close and closed.

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
### `Effect.spawn(fn, id, scope, owner) -> Effect`

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

See [Fibers for Roblox](guide/roblox.md).

## Advanced public modules

The following modules are public but intended mainly for facility authors, embedders or constrained ports:

- `fibers.resource.authoring`
- `fibers.resource.machine`
- `fibers.resource.keyed`
- `fibers.resource.index`
- `fibers.resource.lease`
- `fibers.resource.ref_count`
- `fibers.embed.external`
- `fibers.embed.manual`
- `fibers.embed.queue`
- the exact I/O and embedding modules listed in `packages/public_modules.lua`

Their contracts are documented in [Extending Fibers](advanced/extending.md), [Embedding](guide/embedding.md), [Flow and Stream contract](guide/resources.md#detailed-flow-and-stream-contract) and the design documents. Modules under `fibers.internal.*` are not public API.
