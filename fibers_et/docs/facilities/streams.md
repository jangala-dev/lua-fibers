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

The first implementation is in-memory only.  It provides the stream algebra
needed before host-backed files, sockets and subprocess pipes are added.

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

## Future host-backed streams

Files, sockets and subprocess pipes should reuse this shape:

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
