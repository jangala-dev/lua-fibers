# Transactional streams

Streams are the first substantial facility built on the public base kit.  A
stream is not a scheduler primitive.  It is an owned transactional byte
boundary.

```text
Reads consume committed bytes.
Writes publish committed bytes.
Backpressure is committed capacity.
EOF and half-close are committed state.
Losing alternatives leave no byte trace.
```

The first implementation provided in-memory streams.  The current stream facility
also includes a host-pumped stream substrate with a fake backend for tests and
examples.  Real files, sockets and subprocess pipes should reuse the same pump
contract rather than inventing separate stream runtimes.

## Public shape

```lua
local fibers = require('fibers')
local Stream = fibers.Stream

local a, b = Stream.memory_pair({ capacity = 4096 })
```

Each endpoint supports single-commit operations:

```lua
stream:read_some_op(max)
stream:read_exactly_op(n)
stream:read_line_op(opts)

stream:write_op(bytes)
stream:write_some_op(bytes)

stream:flush_op()
stream:shutdown_read_op(reason)
stream:shutdown_write_op(reason)
stream:close_op(reason)
stream:state_op()
stream:closed_op()
```

The `_op` suffix is significant: these operations describe one transaction
attempt.  Friendly methods such as `stream:write(bytes)` may perform repeatedly
and therefore may commit more than one transaction.

## Memory stream pairs

A memory pair is two endpoints and two transactional byte queues:

```text
A writes -> q_ab -> B reads
B writes -> q_ba -> A reads
```

No host pump and no readiness source are involved.  A committed write appends to
the peer's incoming byte queue.  A committed read consumes from the local
incoming byte queue.

## ByteQueue

The underlying resource is `fibers.facility.stream.byte_queue`.  It is a
specialised transactional byte resource.  It tracks:

```text
buffered bytes in chunked storage
capacity
writer-open state
reader-open state
sticky read/write errors
version
```

Candidate worlds carry ordered byte operations such as append, consume, and
half-close.  The committed implementation stores bytes as chunks rather than as
one monolithic string; speculative views copy chunk references and apply
journalled operations over that view.  This keeps the semantic resource simple
while avoiding the worst behaviour of repeated whole-buffer concatenation.
  Sequential composition preserves order.  Parallel operations on the
same queue are deliberately conservative in this first version and conflict when
both sides try to modify the same byte queue.

## Algebraic laws

The stream facility exists to make these laws true:

```text
losing write branch appends nothing
losing read branch consumes nothing
selected read consumes once
read_exactly waits without consuming partial data
EOF is observed after buffered bytes
reader close causes peer writes to fail with broken_pipe
backpressure is transactional capacity
```

These laws are covered by `tests/test_stream_memory.lua`, including reads across
chunk boundaries and explicit validation for zero-length and invalid operations.


## Host-pumped streams

Host-pumped streams keep the same public endpoint operations, but connect them to
host I/O through pump tasks.

```text
host -> read pump -> incoming ByteQueue -> user reads
user writes -> outgoing ByteQueue -> write pump -> host
```

The constructor is transactional:

```lua
local stream = fibers.perform(Stream.open_backend_op(region, backend, {
  name = 'host-stream',
  read_capacity = 4096,
  write_capacity = 4096,
}))
```

Opening commits three things together:

```text
stream endpoint admitted to the Region
read pump Task admitted and spawned
write pump Task admitted and spawned
```

If an open operation loses a choice, no pump starts.

The backend contract is intentionally small:

```lua
backend:read_ready_op()
backend:write_ready_op()
backend:read(max)
backend:write(bytes)
backend:shutdown_read(reason)
backend:shutdown_write(reason)
```

`read_ready_op` and `write_ready_op` are ordinary `Op`s, usually backed by
`Source`.  `read` and `write` are called only from pump task bodies after the
readiness operation commits.  Host I/O must never run during transaction search.

### In-flight write claims

Host writes are irreversible once accepted, so the write pump does not simply
consume bytes and then call the backend.  It uses a committed in-flight claim:

```text
claim_for_write_op
  moves bytes from pending output into pump-owned in-flight state

backend:write
  accepts a prefix outside transaction search

ack_claim_op
  commits the accepted prefix and preserves any remainder
```

This gives precise handling of partial writes and would-block results.  `flush_op`
for host-backed streams waits until both pending output and in-flight output are
empty.

### Fake backend

`Stream.backend.Fake` is a deterministic backend for tests and examples.  It can
feed read bytes and EOF, block or unblock writes, impose partial write sizes, and
record what the write pump delivered.  It is not a production backend; it exists
to prove the pump laws before files, sockets and subprocesses are added.


## Readiness-backed streams

Readiness-backed streams are the bridge from the fake pump backend to real
sockets, process pipes and host event loops.  Readiness is represented as a
`Source` discipline with named modes:

```text
read
write
```

The host-facing contract is deliberately small:

```lua
local source, feed = rt:readiness(handle, 'name')

source:readable_op()
source:writable_op()

feed:readable()
feed:writable()
feed:clear(mode)
```

All external readiness changes should pass through the runtime-bound feed.  That
invalidates bounded search cursors in the same step as the readiness mutation.
This is important for embedders which call `runtime:step({ max_work = ... })`.

Readiness is level-like, advisory, and carries no error or close payload:

```text
Readiness says: try the backend operation now.
The backend operation remains authoritative.
It may still return would_block, eof, or an error.
```

A readiness-backed backend therefore implements readiness operations using the
source, but still performs non-blocking host calls in the pump task:

```lua
function backend:read_ready_op()
  return self.readiness:readable_op()
end

function backend:read(max)
  return host_read_nonblocking(handle, max)
end
```

The generic `Stream.backend.Readiness` adapter provides this shape for host
callbacks.  `Stream.backend.Fake` is a deterministic test/example backend; in
manual readiness mode it keeps host state and readiness delivery separate.  For
example, `feed_read(bytes)` only changes the fake host input buffer;
`mark_readable()` is the separate host notification that makes the pump try to
read.

This separation is the key law for real sockets and pipes:

```text
host readiness -> Source wait commits -> pump tries host I/O -> ByteQueue commit
```

No host I/O runs during transaction search.

## EOF and half-close

Each byte direction has two pieces of state:

```text
writer_open
  can more bytes be appended?

reader_open
  does the peer still accept bytes?
```

For endpoint `A`:

```lua
A:shutdown_write_op()
```

closes the writer side of `A -> B`, so `B` reads any buffered bytes and then
observes `nil, "eof"`.

```lua
A:shutdown_read_op()
```

closes the reader side of `B -> A`, so future writes by `B` fail with
`nil, "broken_pipe"`.

`close_op` performs both half-closes.

## Backpressure

A memory pair may be bounded:

```lua
local a, b = Stream.memory_pair({ capacity = 3 })
```

`write_op(bytes)` is all-or-nothing.  It waits until the whole byte string can
fit.  If the byte string is larger than the total capacity, it returns
`nil, "too_large"`.

`write_some_op(bytes)` may append a non-empty prefix when capacity is available.
It is intended for friendly looping methods.


## Byte storage

The first implementation uses a portable Lua chunk queue.  Appends add chunks,
small adjacent chunks may be coalesced, consumes advance a head pointer, and old
consumed chunks are compacted periodically.  Operations that need a string result
such as `read_exactly_op` or `read_line_op` concatenate only the bytes being
returned or searched.

This is still a simple implementation, not a final zero-copy design.  It is,
however, the right boundary: future FFI ring buffers or rope-like storage can
replace the storage internals without changing stream laws or public operations.

## Transactional protocol steps

The important gain over ordinary streams is that stream operations compose with
state, ownership and effects.

A protocol step can be one committed world:

```lua
local op = stream:read_line_op():and_then(function(line)
  return state:read_op():and_then(function(old)
    local next_state, response = handle(line, old)
    return state:write_op(next_state):and_then(function()
      return stream:write_op(response .. "\n")
    end)
  end)
end)
```

If this operation loses a choice or is cancelled before commit, no request bytes
are consumed and no response bytes are appended.

## Ownership handoff

Stream endpoints are owned handles and can participate in `Region` and
`Lifetime` ownership transfer.

```lua
return stream:read_line_op():and_then(function(prefix)
  if prefix == 'PING' then
    return negotiator:handoff_op(stream, responder):and_then(function()
      return stream:write_op('PONG\n')
    end)
  end
  return stream:close_op('bad protocol')
end)
```

This lets protocol negotiation, state update, response bytes and ownership
handoff commit together.


## Ownership tracking and authority

Stream endpoints are owned handles.  They can be admitted to a `Region`, handed
off through `Lifetime`, and retired like other owned resources.  This ownership
state is real committed state and is useful for leak detection, structured
shutdown, negotiated protocol handoff, and future host-backed stream settlement.

The current stream operations do not yet enforce authority.  In other words,
ownership is tracked, but `read_op`, `write_op` and `close_op` do not currently
require an explicit owner token or current-task authority check.

That is deliberate for this milestone.  It keeps the in-memory stream algebra
focused on byte-state laws while the task/context policy layer is still
settling.  A later authority pass may add one of these forms:

```lua
stream:write_op(bytes, owner_token)
```

or implicit current-task authority through the active launch policy.

Until then, the rule is:

```text
Region/Lifetime ownership records who should own a stream.
It does not yet prevent unrelated code from using the endpoint directly.
```

This distinction should be preserved in tests and documentation.  Handoff tests
prove ownership state changes transactionally; they do not yet prove access
control.

## Future real backends

Files, sockets and subprocess pipes should reuse the host-pumped shape:

```text
ByteQueue
  committed buffered bytes

Source
  host readiness or external occurrence

Task
  read/write pump work

Effect
  committed pump kicks and close/shutdown requests

Region
  ownership of handles, pumps and process obligations
```

Host I/O must not happen during transaction search.  Host-backed streams should
append to and consume from `ByteQueue` through pump tasks and effects after the
relevant transaction commits.


## Host adapter contract for readiness

The stream pump layer does not own the host event loop.  A host adapter receives
pending wait summaries from the runtime, registers whatever OS or application
waits it needs, and later reports readiness through the runtime-bound Source
path.

The small contract is:

```lua
local waits = rt:pending_wait_summary()
local readiness = fibers.host.readiness_waits(waits)

-- when a handle is ready:
rt:arrive(wait.source, wait.mode, true)
```

or, for deterministic tests and simple embedders:

```lua
local host = fibers.host.manual()
host:readable(key)
host:writable(key)
```

`fibers.host.deliver_ready(rt, waits, is_ready)` implements the common delivery
loop used by host adapters.  Readiness is deliberately only a hint.  It wakes the
pump so that the backend can try its non-blocking operation.  The backend call
may still return `would_block`, `eof`, or an error.

## Socket-shaped backend contract

`Stream.backend.Socket` is not tied to any socket library.  It is the backend
shape for hosts that can provide non-blocking read/write functions plus
read/write readiness.

```lua
local backend = Stream.backend.Socket.new {
  key = handle,
  host = host,

  read = function(self, max)
    return host_socket_read_nonblocking(handle, max)
  end,

  write = function(self, bytes)
    return host_socket_write_nonblocking(handle, bytes)
  end,

  shutdown_read = function(self, reason) ... end,
  shutdown_write = function(self, reason) ... end,
  close = function(self, reason) ... end,
}
```

The backend supplies the existing pump contract:

```text
read_ready_op  -> Source readiness read
write_ready_op -> Source readiness write
read(max)      -> bytes | nil, would_block | nil, eof | nil, error
write(bytes)   -> n     | nil, would_block | nil, error
```

The pump clears each consumed readiness hint after an attempted host operation.
If the host is still level-ready, the host adapter may deliver readiness again on
the next block call.  This keeps readiness advisory while avoiding busy loops in
portable test hosts.
