# Transactional flows and streams

The byte-stream facility is built from a smaller primitive:

```text
Inlet  ->  Flow  ->  Outlet
```

An `Inlet` commits bytes into a `Flow`.  An `Outlet` commits bytes out of a
`Flow`.  A bidirectional stream is a compound object built from two flows.

This is deliberately smaller than making a bidirectional stream the primitive.
It supports ordinary streams, one-way pipes, memory pairs, host-pumped sockets,
protocol handoff, transforms, tees, and later reactor-backed pump strategies.

## Public shape

```lua
local fibers = require('fibers')
local Stream = fibers.Stream
local Flow = fibers.Flow

local flow = Flow.new({ capacity = 4096 })
local inlet = flow:inlet()
local outlet = flow:outlet()

inlet:write_op(bytes)
inlet:write_some_op(bytes)
inlet:flush_op()
inlet:shutdown_op(reason)

outlet:read_some_op(max)
outlet:read_exactly_op(n)
outlet:read_line_op(opts)
outlet:read_all_op({ max = n })
outlet:shutdown_op(reason)
```

All handle methods ending in `_op` describe one transaction attempt.  Looping
convenience such as “write all bytes by committing several prefixes” belongs in
an IO helper layer, not on `Inlet`, `Outlet`, `Flow`, or `Stream`.

## Memory stream pairs

A memory pair is two bidirectional compounds made from two flows:

```text
A.writer -> flow_ab -> B.reader
B.writer -> flow_ba -> A.reader
```

```lua
local a, b = Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
local line = fibers.perform(b:reader():read_line_op())
```

There is no host pump and no readiness source.  A committed write appends bytes
to the peer's readable flow.  A committed read consumes bytes from the local
readable flow.

## Host-backed streams

A host stream is a compound owned object over two flows, a backend, and pump
obligations:

```text
backend -> read pump  -> rx Flow -> stream.reader
stream.writer -> tx Flow -> write pump -> backend
```

```lua
local stream = fibers.perform(Stream.open_backend_op(region, backend, {
  name = 'host-stream',
  read_capacity = 4096,
  write_capacity = 4096,
}))

local r = stream:reader()
local w = stream:writer()
```

Opening commits the compound object, the stable reader/writer handles, and the
current pump strategy together:

```text
host stream compound admitted to the Region
reader handle admitted to the Region
writer handle admitted to the Region
read pump Task admitted and spawned
write pump Task admitted and spawned
```

If the open operation loses a choice, no pump starts and the backend is not
attached.

The compound itself does not expose byte operations.  Use `stream:reader()` and
`stream:writer()`.

## Flow internals

A `Flow` is not a queue.  It is a small compound over simpler transactional
resources:

```text
ByteBuffer
  chunked byte storage only: append, consume, consume_some, consume_exactly, line finding, bounded availability, and empty facts

Producer half-state
  open / shutdown / failed for the byte-producing side

Consumer half-state
  open / shutdown / failed for the byte-consuming side

Capacity
  byte credit; ordinary writes reserve it, reads release it, and pumps wait on free_some facts

Pump claim
  optional stream-pump internal state, with inflight and empty facts
```

The public `Inlet` and `Outlet` operations compose these pieces through precise transactional facts.  Broad inspection operations exist for diagnostics, but behavioural code should ask for facts such as buffer consume_some, consume_exactly, line finding, capacity free, half closed, claim inflight, or buffer empty.  Losing alternatives append no bytes, consume no bytes, reserve no capacity, and leave no pump claims behind.

## Algebraic laws

The flow facility exists to make these laws true:

```text
losing write branch appends nothing
losing read branch consumes nothing
selected read consumes once
read_exactly waits without consuming partial data
EOF is observed after buffered bytes
outlet shutdown causes inlet writes to fail with broken_pipe
backpressure is transactional capacity
long reads are observational until commit
```

`read_some_op`, `read_exactly_op`, `read_line_op` and `read_all_op` are
public result shapes over one internal read core.  The core is a choice over
precise transactional facts: byte-storage facts from the buffer, producer
terminal facts from the producing half, and consumer-open facts from the
consuming half.  The buffer owns storage-native facts such as consume_some,
consume_exactly, line finding, and bounded availability; flow code gives those
facts read protocol meaning, commits the selected consume/release, and then maps
the core data/error result to the familiar Lua return shape.

`read_line_op` and `read_all_op` may wait while the committed byte buffer grows.
They inspect committed bytes but consume nothing until their selected world
commits.  If such an operation loses a choice, is cancelled before commit, or is
abandoned by fallback, the bytes remain in the flow.

## Write-side semantics

`inlet:write_op(bytes)` is all-or-nothing:

```text
append all bytes in one commit, or append none
```

For bounded flows, it waits until the whole byte string can fit.  If a byte
string can never fit because it exceeds the capacity, the operation reports
`too_large`.

`inlet:write_some_op(bytes)` appends one non-empty prefix in one commit.  It is
for pump tasks and explicit multi-commit helper programmes.

Large reads can be single transactions because observation is reversible.  Large
writes are single transactions only when the bytes can be appended as one
committed update.  A later `fibers.io.write_all(inlet, bytes)` helper should be
documented as a multi-commit programme, not as one transaction.

## Host backend contract

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

## In-flight write claims

Host writes are irreversible once accepted, so the write pump does not simply
consume bytes and then call the backend.  The split host write pump uses a committed pump-internal in-flight claim:

```text
claim_for_write_op
  moves bytes from pending output into pump-owned in-flight state

backend:write
  accepts a prefix outside transaction search

ack_claim_op
  commits the accepted prefix, releases the corresponding capacity, and preserves any remainder
```

`inlet:flush_op()` waits on precise drain facts: the ordinary buffer is empty and any pump-internal in-flight claim is empty, or the write side has failed. Claimed bytes continue to reserve capacity until acknowledged or settled by close/error policy.

## Pump strategies

The default host strategy starts separate read and write pump tasks:

```text
read pump:
  waits on capacity-free, reader-closed, and backend-ready facts; backend -> read Flow inlet

write pump:
  waits on claim-inflight / buffered-claim / closed-and-drained facts, then backend-ready; write Flow outlet -> backend
```

This is a strategy, not a semantic commitment.  The same host-stream compound
can later be installed by a single per-stream pump, a shared reactor, or a
host-native adapter that feeds and drains flows directly.

## Ownership

Ownership attaches at several levels:

```text
Flow
  owns one directional byte buffer, half-states and capacity

Inlet
  transferable authority to produce bytes

Outlet
  transferable authority to consume bytes

Host stream compound
  owns backend, two flows, pump obligations and settlement state
```

In this WIP, ownership is still mostly tracking rather than access enforcement.
The object model is shaped so authority checks can later be added without
changing the public flow vocabulary.
