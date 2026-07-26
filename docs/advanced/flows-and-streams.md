# Flows, streams and host I/O

`Flow` is the transactional byte-building block. `Stream` is the familiar
readable, writable or duplex facility built over one or two Flows. Host-backed
Streams share one indexed poller and one reactor per Runtime.

The layers have separate responsibilities:

```text
Flow
    byte custody, buffering, backpressure and transactional composition

Stream
    an application-facing reader, writer or duplex byte facility

HostReactor readiness index
    indexed readiness registration and ready-event delivery

HostReactor
    bounded irreversible host reads and writes after commitment
```

Every method ending in `_op` constructs an **option**. It does not act until the
option is submitted to `perform` and selected as part of a committed world.

## Flow

```lua
local Flow = require('fibers.resource.flow')

local flow = Flow.new({
  name = 'request-body',
  capacity = 64 * 1024, -- omit for an unbounded Flow
})

local inlet = flow:inlet()
local outlet = flow:outlet()
```

A Flow has one stable producer endpoint, the `Inlet`, and one stable consumer
endpoint, the `Outlet`:

```text
Inlet → retained byte custody → Outlet
```

### Inlet

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

### Outlet

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

### Whole-Flow methods

```lua
flow:inspect_op()
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

## Data leases

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
lease:inspect()
lease:ack_op(count)
lease:release_op()
lease:fail_op(error)
```

A partial acknowledgement consumes only the acknowledged prefix. The lease
continues to own the suffix. `release_op` returns all unacknowledged bytes to the
Flow unchanged.

## Space leases

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
space:inspect()
space:commit_op(bytes)
space:release_op()
space:fail_op(error)
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

## Stream

A Stream contains no byte state. It is a thin pairing of an optional Flow Outlet
and an optional Flow Inlet. Facility authors may compose existing Flows directly:

```lua
local stream = Stream.compose(read_flow, write_flow, { name = 'duplex' })
```

A memory pair is formed from two cross-connected Flows:

```lua
local Stream = require('fibers.stream')
local a, b = Stream.memory_pair({ capacity = 4096 })

perform(a:write_op('hello\n'))
assert(perform(b:read_line_op()) == 'hello')
```

A host-backed Stream has one constructor:

```lua
local stream = perform(Stream.open_op(handle, {
  scope = scope, -- defaults to the current Scope
  name = 'connection',

  read = true,
  write = true,

  read_capacity = 64 * 1024,
  write_capacity = 64 * 1024,
  read_chunk_size = 16 * 1024,
  write_chunk_size = 16 * 1024,
}))
```

`read` and `write` are required booleans. At least one direction must be
enabled. A `HostHandle` must provide `close`, and must provide `read` or `write`
for each enabled direction.

Ordinary socket, file and process users will normally receive Streams from those
facilities rather than call `Stream.open_op` directly.

### Stream capabilities

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

### Stream byte methods

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

### Stream closure

```lua
stream:shutdown_read_op(reason)
stream:shutdown_write_op(reason)
stream:abort_write_op(reason)
stream:close_op(reason)
stream:abort_op(reason)
stream:closed_op()
stream:inspect_op()
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

## Indexed poller and reactor

Every host-backed direction receives an indexed poller registration containing a
stable id, generation, readiness key and direction. The poller delivers only the
ready subset through a persistent FIFO; it does not rebuild an option tree
containing every Stream.

Linux epoll stores a fresh registration epoch in each armed event token. A stale
kernel event must resolve through the current epoch before the reaction id and
generation are accepted.

The reactor waits on compact control and readiness options:

```lua
choice(control_op, poller:next_op())
```

The reactor drains a bounded control burst before waiting. Control and host
readiness are then temporal alternatives, so `choice` keeps both waits live. If
readiness wins, the reactor drains newly queued control before attempting the
host action; retirement and demand changes therefore take effect first without
misusing certified fallback for a temporal race.

Flow demand reaches the reactor through an internal typed consequence. Every
state-changing Flow option selects a deduplicated `flow_changed` effect in the
same candidate world. The effect is discharged only after that world commits;
losing and rolled-back alternatives therefore produce no notification. Its
discharge enqueues the Flow identity, and the reactor refreshes only the indexed
registrations attached to that Flow. Flow does not patch Scalar locations or
expose a public observer API.

For reads, the reactor reserves Flow capacity before performing the authoritative
host call. For writes, it leases committed bytes before the call. `would_block`
releases read capacity or retains write custody as appropriate.

The `HostHandle` contract is:

```text
handle.key or handle:readiness_key()
handle:read(maximum)           -- required for readable Streams
handle:write(bytes)            -- required for writable Streams
handle:shutdown_read(reason)   -- optional
handle:shutdown_write(reason)  -- optional
handle:close(reason)           -- mandatory
```

`read` and `write` must be non-blocking. Readiness is only a hint. The reactor
accepts these read results:

```text
non-empty string, nil       bytes were read
nil or empty string, EOF    terminal EOF
non-empty string, EOF       final bytes followed by EOF
nil or empty string, would_block
                            stale readiness
nil, another error          terminal read failure
```

Ambiguous or oversized results fail the direction with a HostHandle protocol error.

Regular files may block despite appearing ready. They should use an asynchronous
host job service while retaining Flow leases as their byte boundary.
