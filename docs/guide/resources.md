# Resources

This guide introduces the host-neutral facilities used to build Fibers applications. Every facility offers options; selected facilities also provide direct methods which perform those options.

For exact signatures, see the [API reference](../api-reference.md). For building a new transactional facility, see [Extending Fibers](../advanced/extending.md).

## Channels

```lua
local channel = require('fibers.channel')

local synchronous = channel.new()
local bounded = channel.new(16)
local unbounded = channel.new(math.huge)
```

Channels support:

```lua
channel:put_op(value)
channel:get_op()
channel:put(value)
channel:get()
```

Capacity zero is synchronous rendezvous. Positive capacity is FIFO buffering.

## Cells

```lua
local Cell = require('fibers.resource.cell')
local state = Cell.new('idle')
```

Common operations:

```lua
state:read_op()
state:changed_op(version)
state:expect_op(value)
state:write_op(value)
state:wait_until_op(predicate)
state:match_op(matcher)
```

`expect_op` and `write_op` compose naturally:

```lua
state:expect_op('idle')
  :and_then(state:write_op('running'))
```

`wait_until` returns the complete satisfying value. `match` uses a truthy leading matcher result and returns the remaining projected values.

## Counters and capacity

```lua
local Counter = require('fibers.resource.counter')

local count = Counter.new(0)
local slots = Counter.bounded(16)
local percentage = Counter.range(50, 0, 100)
```

Counters support reads, changes, adjustments and predicates:

```lua
count:read_op()
count:add_op(1)
count:take_op(1)
count:give_op(1)
count:at_least_op(10)
count:at_most_op(20)
count:equal_op(0)
count:zero_op()
```

A bounded counter is useful for transactional admission:

```lua
slots:take_op(1)
  :and_then(queue:put_op(work))
```

## Semaphores

`fibers.semaphore` provides a conventional capacity view over a bounded counter:

```lua
local Semaphore = require('fibers.semaphore')
local semaphore = Semaphore.new(8)

semaphore:acquire(1)
semaphore:release(1)
```

Use the underlying Counter when its richer algebra is useful.

## Pulses

A Pulse represents coalescing change notification:

```lua
local Pulse = require('fibers.pulse')
local changed = Pulse.new()

local version = changed:version()
changed:signal()
local next_version = changed:changed(version)
```

Pulses support closure and an optional reason. They are suitable when the program needs to know that something changed, rather than receive every individual event.

## Latches

A Latch is set once and thereafter retains its value:

```lua
local Latch = require('fibers.latch')
local ready = Latch.new()

ready:set(configuration)
local value = ready:get()
```

## Mailboxes

A Mailbox has split sender and receiver endpoints:

```lua
local Mailbox = require('fibers.mailbox')
local tx, rx = Mailbox.new(64)

local clone = tx:clone()
tx:send(value)
local received = rx:recv()
```

Alternative overflow policies include rejecting the newest message or dropping the oldest.

Sender closure, closure reason and dropped-message state are explicit.

## Signals and event queues

Lower-level facilities include:

- `fibers.resource.signal` for a simple waitable signal;
- `fibers.resource.event_queue` for transactional event admission and retrieval;
- `fibers.resource.rendezvous` for exact synchronous exchange;
- `fibers.resource.fifo` for a FIFO resource;
- `fibers.resource.index` and `fibers.resource.keyed` for transactional collections.

Most application code should use channels, Mailboxes or Pulses unless it needs the lower-level law directly.

## Time

```lua
local Sleep = require('fibers.sleep')

Sleep.sleep(0.25)
Sleep.sleep_until(deadline)
```

Their `_op` forms compose with any option:

```lua
local result = fibers.perform(Op.choice(
  reply_op,
  Sleep.sleep_op(5):map(function()
    return nil, 'deadline reached'
  end)
))
```

## Flows

`fibers.resource.flow` is the transactional byte-flow building block.

```lua
local Flow = require('fibers.resource.flow')
local flow = Flow.new(64 * 1024)
local inlet = flow:inlet()
local outlet = flow:outlet()
```

The inlet supports writes, partial writes, space reservation, flush and closure.

The outlet supports partial and exact reads, delimiter scanning, line reads, complete reads, dropping, splicing and data leases.

Flow operations preserve backpressure and participate in `choice`, `and_then`, `each` and `together`.

The detailed Flow and Stream contracts follow below.

## Streams

`fibers.stream` composes one or two Flows into readable, writable or duplex Streams:

```lua
local Stream = require('fibers.stream')
local a, b = Stream.memory_pair({ capacity = 64 * 1024 })
```

Streams support:

- partial and exact reads;
- delimiter and line reads;
- complete reads with limits;
- writes and flush;
- independent read and write shutdown;
- complete close and abort;
- local and peer address metadata where available.

Portable Streams do not import host I/O. Host-backed Streams are provided through `fibers.io.stream`, sockets, pipes and processes.


## Detailed Flow and Stream contract

The following section is the complete practical contract for portable byte flows and streams. Host reactor mechanics are documented in [I/O design](../design/io.md).

### Flow

```lua
local Flow = require('fibers.resource.flow')

local flow = Flow.new(64 * 1024):label('request-body')

local inlet = flow:inlet()
local outlet = flow:outlet()
```

The capacity is the constructor argument; pass `nil` for an unbounded Flow. Attach optional diagnostic context separately with `:label(...)`.

A Flow has one stable producer endpoint, the `Inlet`, and one stable consumer
endpoint, the `Outlet`:

```text
Inlet → retained byte custody → Outlet
```

#### Inlet

The complete producer surface is:

```lua
inlet:write_op(bytes)
inlet:write_some_op(bytes)
inlet:reserve_some_op(maximum, holder, meta)
inlet:flush_op()
inlet:close_op(reason)
inlet:closed_op()
inlet:fail_op(error)
```

`write_op` accepts the complete string or waits. It returns the number of bytes
accepted, or `nil, error`.

`write_some_op` accepts a non-empty prefix when capacity is available. It
returns:

```text
count, remaining_bytes
nil, original_bytes, error
```

A zero count with no error means that no progress was possible in that committed
state.

`flush_op` waits until no queued, leased or reserved bytes remain.

`close_op` gracefully closes production. Retained bytes remain available and
the Outlet observes EOF after consuming them.

`fail_op` closes production with an error which readers subsequently observe.

#### Outlet

The complete consumer surface is:

```lua
outlet:read_some_op(maximum)
outlet:read_exactly_op(count)
outlet:read_until_op(separator, opts)
outlet:read_line_op(opts)
outlet:read_all_op(opts)
outlet:peek_exactly_op(count)
outlet:drop_op(count)
outlet:splice_to_op(inlet, count)
outlet:lease_some_op(maximum, holder, meta)
outlet:close_op(reason)
outlet:closed_op()
outlet:fail_op(error)
```

`read_some_op` waits for at least one byte and returns no more than the requested
maximum. At terminal EOF it returns `nil, Flow.Error.EOF`.

`read_exactly_op` waits for the requested count. If EOF arrives first, it
returns:

```text
nil, Flow.Error.EOF, partial_bytes
```

`read_until_op` uses:

```lua
outlet:read_until_op('\r\n\r\n', {
  include = false,
  max = 32 * 1024,
})
```

`max` defaults to 8192. EOF before the separator returns `nil,
Flow.Error.EOF, partial_bytes`.

Delimiter matching is incremental. Flow's persistent Rope retains a KMP search
state for each active separator. The first search scans the retained bytes once;
subsequent appends advance only across the newly appended chunks, including a
separator split across chunk boundaries. Prefix consumption invalidates the
derived cache. Delimiter reads therefore do not flatten and rescan the complete
buffer after every partial host read.

`read_line_op` uses line-specific names and EOF behaviour:

```lua
outlet:read_line_op({
  terminator = '\n',
  keep_terminator = false,
  max = 8192,
})
```

A final unterminated line is returned normally. EOF with no retained bytes
returns `nil, Flow.Error.EOF`.

`read_all_op` requires an explicit bound:

```lua
outlet:read_all_op({ max = 1024 * 1024 })
```

Code which deliberately accepts unbounded input may pass `math.huge`.

`peek_exactly_op` waits until the requested prefix is available without
consuming it. `drop_op` consumes exactly the requested count.

`splice_to_op` moves exactly the requested count between Flows in one
transactional composition.

`close_op` means that the consumer has abandoned the Flow. Retained bytes are
settled and future writes fail with `Flow.Error.BROKEN_PIPE`.

#### Whole-Flow methods

```lua
flow:abort_op(reason)
flow:closed_op()
```

`abort_op` forces both endpoints terminal and settles all queued, leased and
reserved custody. It is deliberately named differently from `Inlet:close_op`,
which is graceful producer EOF.

`closed_op` becomes available only when both endpoints are terminal and no byte
or capacity custody remains. It returns `nil, closure_error` if Closure
failed.

The public stable error vocabulary is:

```lua
Flow.Error.EOF
Flow.Error.CLOSED
Flow.Error.BROKEN_PIPE
Flow.Error.TOO_LARGE
Flow.Error.LINE_TOO_LONG
Flow.Error.RETIRED
```

The retained-byte state, transition vocabulary and concrete lease classes are
implementation details and are not module exports.

### Data leases

A data lease gives an external consumer committed custody of a retained byte
prefix:

```lua
local lease = perform(outlet:lease_some_op(4096, driver))
local written, err = host_write(lease:bytes())

if written then
  perform(lease:ack_op(written))
elseif err == 'would_block' then
  -- Keep the lease and try again after refreshed readiness.
else
  perform(lease:fail_op(err))
end
```

Its complete surface is:

```lua
lease:bytes()
lease:length()
lease:ack_op(count)       lease:ack(count)
lease:release_op()        lease:release()
lease:fail_op(error)      lease:fail(error)
```

A partial acknowledgement consumes only the acknowledged prefix. The lease
continues to own the suffix. `release_op` returns all unacknowledged bytes to the
Flow unchanged.

### Space leases

A space lease is the symmetrical producer-side boundary. It reserves capacity
before an external source obtains bytes:

```lua
local space = perform(inlet:reserve_some_op(4096, driver))
local bytes, err = host_read(space:capacity())

if bytes then
  perform(space:commit_op(bytes))
elseif err == 'would_block' then
  perform(space:release_op())
else
  perform(space:fail_op(err))
end
```

Its complete surface is:

```lua
space:capacity()
space:commit_op(bytes)   space:commit(bytes)
space:release_op()        space:release()
space:fail_op(error)      space:fail(error)
```

Reserved capacity counts against the Flow limit. `commit_op` publishes no more
than the reservation and releases any unused part.

Together, the leases form the irreversible boundary:

```text
space lease
    capacity is committed before an external producer obtains bytes

data lease
    bytes are committed before an external consumer removes them
```

### Stream

A Stream contains no byte state. It is a thin pairing of an optional Flow Outlet
and an optional Flow Inlet. Facility authors may compose existing Flows directly:

```lua
local stream = Stream.compose(read_flow, write_flow):label('duplex')
```

A memory pair is formed from two cross-connected Flows:

```lua
local Stream = require('fibers.stream')
local a, b = Stream.memory_pair({ capacity = 4096 })

perform(a:write_op('hello\n'))
assert(perform(b:read_line_op()) == 'hello')
```

A host-backed Stream is an I/O facility layered over the portable Stream value:

```lua
local HostStream = require('fibers.io.stream')
local stream = perform(HostStream.open_op(handle, {
  scope = scope, -- defaults to the current Scope

  read = true,
  write = true,

  read_capacity = 64 * 1024,
  write_capacity = 64 * 1024,
  read_chunk_size = 16 * 1024,
  write_chunk_size = 16 * 1024,
}))
stream:label('connection')
```

`read` and `write` are required booleans. At least one direction must be
enabled. A `HostHandle` must provide `close`, and must provide `read` or `write`
for each enabled direction.

Ordinary socket, file and process users will normally receive Streams from those
facilities rather than call `HostStream.open_op` directly. `fibers.stream.open_op` has been removed; host-backed streams use `fibers.io.stream.open_op`.

#### Stream capabilities

```lua
stream:is_readable()
stream:is_writable()
stream:is_duplex()
stream:reader() -- Flow Outlet or nil
stream:writer() -- Flow Inlet or nil
```

Using a missing direction through a forwarding method is a programming error.
Expected I/O conditions such as EOF, broken pipe and connection reset remain
result values.

#### Stream byte methods

The familiar application-facing surface is:

```lua
stream:read_some_op(maximum)
stream:read_exactly_op(count)
stream:read_until_op(separator, opts)
stream:read_line_op(opts)
stream:read_all_op(opts)

stream:write_op(bytes)
stream:write_some_op(bytes)
stream:flush_op()
```

The methods delegate to the configured Flow endpoints. Facility authors use
`reader()` and `writer()` when they need peeking, splicing or leases.

#### Stream closure

```lua
stream:shutdown_read_op(reason)
stream:shutdown_write_op(reason)
stream:abort_write_op(reason)
stream:close_op(reason)
stream:abort_op(reason)
stream:closed_op()
```

`shutdown_read_op` abandons the read direction and retires its host reaction.

`shutdown_write_op` stops accepting writes, drains retained output, performs
host half-shutdown and retires the write reaction.

`abort_write_op` discards retained output and retires without waiting for host
writability.

`close_op` is graceful user closure: it abandons reading, drains writing, closes
the HostHandle and waits for completed Closure.

`abort_op` abandons both directions, discards queued output and waits for prompt
completed Closure. Scope cancellation and failure Closure use the abortive
form.

`closed_op` observes completed direction retirement, HostHandle closure and any
close error.

Custody movement uses the general Lifetime API. Stream provides no transfer
aliases. Facilities needing halves under independent custody construct separate
read-only and write-only Stream roots, as pipes and process standard streams do.

## Diagnostic labels

All identity-bearing resources receive stable internal IDs. Add a human label only when it improves diagnostics:

```lua
local commands = channel.new(16)
  :label('service-commands')
```

Labels do not affect transactional semantics, capacity or matching. Most local resources need no label.

## Resource selection

Prefer the smallest facility whose law matches the application:

| Need | Facility |
|---|---|
| one synchronous or buffered message stream | Channel |
| one replaceable fact | Cell |
| transactional capacity or count | Counter |
| coalescing change notification | Pulse |
| one eventual value | Latch |
| split multi-sender messaging | Mailbox |
| byte flow with backpressure | Flow or Stream |
| a custom state machine | `fibers.resource.machine` |

Build larger application operations by composing existing options before authoring a new primitive resource.
