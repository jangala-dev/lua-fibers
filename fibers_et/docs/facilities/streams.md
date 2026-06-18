# Transactional flows and streams

The byte facility is built from a directional primitive:

```text
Inlet  ->  Flow  ->  Outlet
```

A `Flow` is a directional byte medium.  Its core resource is a reservoir of
retained bytes.  Bytes may be queued or leased.  Capacity is an invariant over
all retained bytes.  Input and output endpoint state governs whether bytes may
enter or leave.  The current reservoir is backed by a pure Lua rope of immutable
string chunks rather than by one repeatedly concatenated string.  Text and
protocol awareness, such as line endings and delimiters, lives above the
reservoir in algebraically derived Outlet operations.

A bidirectional stream is not primitive:

```text
Stream(A, B) = Flow(A -> B) tensor Flow(B -> A) + lifetime policy
```

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

inlet:write_op(bytes)          -- familiar stream name
inlet:write_some_op(bytes)
inlet:append_op(bytes)         -- algebraic Flow alias
inlet:append_some_op(bytes)
inlet:flush_op()               -- familiar alias
inlet:drain_op()               -- preferred byte-fate name
inlet:shutdown_op(reason)

outlet:read_some_op(max)
outlet:read_exactly_op(n)
outlet:peek_op(n)
outlet:peek_some_op(max)
outlet:drop_op(n)
outlet:read_until_op(term, opts)
outlet:read_including_op(term, opts)
outlet:read_line_op(opts)
outlet:read_all_op({ max = n })
outlet:splice_to(inlet, max)
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

A host-backed stream can be opened directly from any object satisfying the
`HostHandle` contract:

```lua
local handle = fibers.host.Handle.fake({ host = host, key = 'demo' })
local stream = fibers.perform(Stream.open_handle_op(region, handle, {
  name = 'handle-stream',
}))
```

`fibers.facility.stream.backend.handle` adapts a HostHandle into the backend
contract below.  Real fd handles are obtained from the selected host family, for
example `fibers.host.luajit_linux().fd`, `fibers.host.luaposix().fd`, or
`fibers.host.nixio().fd`.


## Flow internals

A `Flow` is a small compound over two kinds of fact:

```text
Reservoir
  queued bytes
  leased bytes
  capacity invariant over retained bytes

Input endpoint
  open / closed / failed for bytes entering the flow

Output endpoint
  open / closed / failed for bytes leaving the flow
```

The important invariant is:

```text
retained = queued + leased
free     = capacity - retained
```

So there is no separate capacity resource and no separate pump-claim resource.

Terminal byte-fate rules are:

```text
producer/input shutdown
  graceful EOF after retained bytes drain

consumer/output shutdown
  retained bytes are discarded and writers/flushers waiting on those bytes
  observe the shutdown reason, or broken_pipe if no reason was supplied

output/backend failure
  retained bytes are failed/settled and writers/flushers waiting on those bytes
  observe the failure
```

A host write pump leases bytes from the reservoir.  Leased bytes remain retained
and continue to occupy capacity until the lease is acknowledged, returned,
failed, or settled.  If the consumer/output side closes, or a backend write
fails, retained queued bytes and active leases are settled in the same committed
transition that records that terminal fact.  This implementation deliberately permits only one active
lease per reservoir; that conservative rule preserves stream ordering until a
later ordered multi-lease model is needed.

The public `Inlet` and `Outlet` operations compose these facts.  Losing
alternatives append no bytes, consume no bytes, and create no leases.

## Algebraic laws

The flow facility exists to make these laws true:

```text
losing write branch appends nothing
losing read branch consumes nothing
selected read consumes once
read_exactly waits without consuming partial data
EOF is observed after queued bytes
outlet shutdown causes inlet writes to fail with broken_pipe
backpressure is retained-byte capacity
long reads are observational until commit
leased bytes still reserve capacity
```

`read_some_op`, `read_exactly_op`, `read_all_op`, `peek_op`, `drop_op`,
`read_until_op`, `read_including_op` and `splice_to` are public result shapes
over the byte reservoir and endpoint facts.

Delimiter helpers are intentionally above the reservoir.  `read_until_op(term)`
consumes through `term` and returns the prefix before `term`;
`read_including_op(term)` consumes through `term` and returns the bytes including
`term`.  `read_line_op` is a small consumer of those helpers, normally using
`\n` and returning a final unterminated line on EOF.  The default delimiter partial
policy reports `nil, eof, partial` and consumes the terminal partial; callers may
choose `partial = 'return'` or `partial = 'discard'`.  `read_all_op` is the sibling
operation bounded by terminal state rather than by a byte terminator.

`peek_op` and `peek_some_op` observe committed bytes without consuming them, even
when the selected world commits.  Internally, the Flow layer builds a speculative
read view: observed bytes or terminal error, plus the reservoir prefix length to
free if a consuming operation is selected.  Reads are deliberately derived from
that view followed by committed reservoir prefix freeing.  `drop_op` is the same
idea with the observed bytes discarded.  `splice_to` is algebraically derived as
view destination-write source-free: destination write failure leaves the source
untouched, while a successful splice frees the source prefix and appends it to
the destination Inlet in one committed world.

Long reads and delimiter reads may wait while the committed reservoir grows.
They inspect committed bytes but free no reservoir prefix until their selected
world commits.  If such an operation loses a choice, is cancelled before commit,
or is abandoned by fallback, the bytes remain in the flow.

The reservoir itself intentionally has no read policy.  It stores retained bytes,
exposes prefixes, frees exact prefixes, leases exact prefixes to pumps, and
records fate.  Operations such as exact reads, delimiter reads, drops and splices
are Flow-level compositions over those smaller reservoir facts.

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

If a backend returns `would_block`, the readiness hint that led to the host call
must be cleared or consumed before waiting again.  Readiness is a hint; the host
operation remains authoritative.

## Byte leases

Host writes are irreversible once accepted, so the write pump does not simply
consume queued bytes and then call the backend.  It uses reservoir leases:

```text
lease_some_op
  moves queued bytes to a lease owned by the pump/stream

backend:write
  accepts a prefix outside transaction search

ack_lease_op
  commits the accepted prefix and preserves any remainder in the lease
```

`inlet:flush_op()` waits on precise fate facts for bytes retained when the
flush attempt begins.  Success means no prior bytes are still retained.  If those
retained bytes are discarded or failed by consumer shutdown or backend failure,
flush returns that settlement error.  If prior bytes have already been consumed,
flush succeeds even if the peer has since closed; a later write is the operation
that observes future writability.  Leased bytes continue to reserve capacity
until acknowledged or settled.  A second lease request by another owner reports
`lease_already_active` while any lease remains active.

## Pump strategies

The default host strategy starts separate read and write pump tasks:

```text
read pump:
  waits on reservoir-free, reader-closed, and backend-ready facts;
  backend -> read Flow inlet

write pump:
  waits on existing lease / queued bytes / closed-and-drained facts,
  then backend-ready; write Flow outlet -> backend
```

This is a strategy, not a semantic commitment.  The same host-stream compound
can later be installed by a single per-stream pump, a shared reactor, or a
host-native adapter that feeds and drains flows directly.

## Ownership

Ownership attaches at several levels:

```text
Flow
  directional byte medium: reservoir plus endpoints

Inlet
  transferable authority to produce bytes

Outlet
  transferable authority to read, free or lease bytes

Host stream compound
  owns backend, two flows, pump obligations and settlement state
```

In this WIP, ownership is still mostly tracking rather than access enforcement.
The object model is shaped so authority checks can later be added without
changing the public flow vocabulary.
