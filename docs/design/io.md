# I/O design

This document specifies the trusted substrate shared by pipes, Streams, stream sockets, regular files, datagrams and processes. Application use is documented in [I/O](../guide/io.md); portable Flow and Stream use is documented in [Resources](../guide/resources.md).

## Host actions occur after commitment

Options may describe acquisition, admission, custody movement, closure requests
and readiness observations. They must not create, accept, connect, read, write or
close host objects while an option is being searched.

After commitment, either a facility driver or the indexed reactor performs the
authoritative host action. Readiness is only a hint that such an action may make
progress; `read`, `write`, `accept`, `finish_connect` and process-exit probes may
still return `would_block`.


## One Flow byte plane, different host engines

Streams and regular files share one data-plane law. Incoming host bytes enter a
Flow only through a committed space reservation; outgoing bytes leave a Flow
only while held by a committed lease. The internal Flow-transfer helper owns
settlement of those reservations and leases, including partial writes, EOF,
`would_block`, protocol failures and byte-custody acknowledgement.

```text
read side:   reserve Flow space -> host read  -> commit/release/fail space
write side:  lease Flow bytes   -> host write -> acknowledge/retain/fail lease
```

What differs is only how the host engine becomes runnable. Stream sockets and
pipes use Reactor readiness. Regular files use a private completion-driven
Lifetime because a regular descriptor cannot truthfully be treated as a
non-blocking readiness source. The Flow boundary after the host call is the
same in both cases.

Consequently a RegularFile data operation is not a request/completion RPC.
`read_op`/`read_some_op` consumes RX Flow state transactionally. `write_op`
transfers byte responsibility transactionally into the TX Flow. Host completion
is relevant to `flush`, `sync`, cursor barriers and Closure, not to whether the
byte admission transaction itself committed.

A regular file additionally maintains cursor reconciliation state. Bounded
read-ahead may move the provider cursor beyond the application cursor. Seek and
write invalidate the current read generation and discard incompatible buffered
bytes transactionally; stale in-flight reads cannot publish into the new
generation. Before a cursor-sensitive host action, the driver rewinds the
provider by the accumulated unread/stale byte debt. This preserves the logical
file cursor without weakening Flow's monotonic endpoint-closure law at EOF.

## Continuous handle coverage

Every acquired host handle follows this lifecycle:

```text
created -> held -> admitted -> closing -> closed
```

`held` means that the running Lifetime covers the handle immediately after the
irreversible host return and before permanent child admission. `admitted` means
that a Stream, Listener, Dial or other structural Lifetime has taken custody.
Failed partial construction closes every handle which remains in a host hold.

A handle must never have two custodians. Moving a handle from a private host
hold into a resource Lifetime is a hand-off, not a second acquisition.

## Reactor registrations

Each readiness-driven Stream direction owns one reactor registration:

```text
created -> registered -> retired
```

Registration identity contains a generation. A readiness delivery for an older
generation is stale and cannot invoke the backend. Retirement removes the
registration from the indexed poller before its resource can close.

The reactor performs bounded work:

- `read_quantum` bounds one read service;
- `write_quantum` bounds one write service;
- `control_quantum` bounds control messages drained before returning to ready
  work;
- `would_block` disarms the registration until readiness is delivered again.

No fairness stronger than bounded service and repeated queue progress is
currently promised. Host backends must not depend on source order among ready
registrations.

## Facility closure conformance

For every host-backed facility, `closed_op` denotes completed structural
retirement. It must not become ready merely because a host completion or local
state flag was published. Where a private driver exists, closure includes the
complete driver body and its private Scope.

The built-in audit applies this rule as follows:

| Facility | Completion observed by `closed_op` |
|---|---|
| Regular file | host file terminal state and private file-driver Scope |
| Process | cached process terminal state, reactor-owned exit completion, generated Streams, bridges and supervisor Scope |
| Resolver query | both address-family completions and private resolver-driver Scope |
| Direct and named dial | dial lifecycle terminal state and private dial-driver Scope |
| Listener | listener terminal state, accepted-handle hold and accept-source registration |
| Datagram | datagram terminal state and private driver Scope |
| Duplex Stream | both Flow endpoints, reactor registrations and host handle |
| Flow endpoint | managed Flow terminal state and retirement of outstanding byte custody |

The reusable regression in `tests/internal/test_closed_op_conformance.lua`
forces a host terminal signal to arrive before a delayed private descendant.
Any facility using the shared driver-closure rule must continue waiting until
that descendant retires.

## Stream closure

A Stream distinguishes requesting closure from observing completed closure.

```lua
stream:close_op(reason)
stream:closed_op()
```

A completed close means that:

- both Flow directions have reached their requested terminal state;
- the associated reactor registrations have retired;
- the backend handle has been closed or its close failure has been retained;
- the Stream's subtree is ready to finish under its custody.

`shutdown_read_op` and `shutdown_write_op` are directional. Graceful write
shutdown first permits already admitted bytes to drain. Abortive closure may
retire queued work immediately.

A peer read shutdown is error-ready for a writer: the next authoritative write
must run and report `broken_pipe`, rather than waiting forever for successful
writability.

## Process custody and reaping

A Process is an external-resource Lifetime held in custody:

```text
Process
├── host process handle
├── supervisor task
├── launch host hold
├── generated standard Streams
├── optional Stream bridge tasks
├── reactor-owned exit completion
└── cached terminal status
```

Process creation uses an exec-error handshake. A successful fork is not a
successful `Command:start`; the child must complete working-directory,
environment, session, process-group, descriptor and exec setup. Every failure
path closes partial pipes and reaps the failed child before returning.

The supervisor is the single authority for signal delivery, exit observation
and reaping. These invariants apply:

- every child handle enters a host hold before the acquiring driver may yield;
- a returned Process has exactly one reap authority;
- `result_op` becomes ready only after exactly-once reaping;
- repeated result observations return the same tagged status;
- Scope Closure cannot finish successfully while it has custody of an unreaped child;
- generated pipe Streams and the exit completion remain beneath the Process supervisor Scope;
- supplied Streams remain in caller custody and are bridged rather than silently moved;
- `closed_op` proves Closure of the host handle, exit completion, Streams, bridges and supervisor.

Native bindings should use a stable process identity, such as a pidfd, where
available. A fallback process strategy must serialise signal and reap decisions so a
reused numeric PID cannot be targeted after the child Lifetime has terminated.

`communicate` is deliberately a direct post-commit procedure. External input
must be delivered before child exit can be observed, so it cannot truthfully be
represented as one speculative all-or-nothing option. Output readers run concurrently, and an output-collection error requests
Process Closure before returning.

`Command:launch_op` is different: a guard constructs a fresh Process during the
current synchronisation attempt, while a committed supervisor-spawn effect
performs the irreversible launch afterwards. The option means that custody of
a launch attempt has committed; `Process:launch_result_op` observes the later
exec handshake.

## Internal qualification instrumentation

The audit is observational and does not affect production semantics. It uses
weak references so inspection cannot retain resources.

```lua
local IO = require('fibers.diagnostics.io')
IO.enable()
local audit = IO.report(runtime, {
  include_history = true,
})

IO.assert_clean(runtime, { label = 'after server shutdown' })
```

The audit reports live handle and registration states, close attempts,
service counts, lifecycle violations and aggregate reactor statistics. A clean
runtime has no live handles, no live registrations and no recorded custody violations.

The reactor also exposes:

```lua
local registrations = runtime.host_reactor:_registration_count()
runtime.host_reactor:_assert_quiescent('after shutdown')
```

These methods are intended for tests, embedders and diagnostics. The underlying
`fibers.diagnostics.io` module remains internal.

## Host contract

Every host declares socket support explicitly:

```lua
host:feature('socket')
host:feature('socket_ipv4')
host:feature('socket_ipv6')
host:feature('socket_unix')
```

A `true` family capability commits the host to the common contract suite. A
`false` capability must produce a structured `unsupported` result rather than a
module-load failure or a weaker approximation.

A conforming stream-socket host must preserve:

- non-blocking connect completion through an authoritative finish call;
- bounded listener acceptance and custody of queued connections;
- local and peer address metadata;
- half-close and EOF behaviour;
- structured refusal, address-conflict, closed and broken-pipe errors;
- generation-safe readiness registration;
- complete handle, task and registration Closure.


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
registrations attached to that Flow. Flow does not patch Cell locations or
expose a public observer API.

For reads, the reactor reserves Flow capacity before performing the authoritative
host call. For writes, it leases committed bytes before the call. `would_block`
releases read capacity or retains write custody as appropriate.

The same index services bounded host-owned offers used by accepted connections,
connection completions, process exits and received datagrams. An offer source
reserves capacity before its authoritative non-blocking host call and publishes a
completed value through an external `EventQueue`. A committed `next_op()` both
claims the value and returns capacity; its post-commit reactor-demand effect
rearms the source. Unclaimed values remain under the source Lifetime and are
disposed during retirement. Offer sources add registrations, not tasks. Providers
which already have request-indexed completions, such as `io_uring`, may instead
register one bounded non-yielding reactor callback which drains their shared
completion queue and publishes the existing per-request Completion values.

The `HostHandle` contract is:

```text
handle.key or handle:readiness_key()
handle:read(maximum)           -- required for readable Streams
handle:write(bytes)            -- required for writable Streams
handle:shutdown_read(reason)   -- optional
handle:shutdown_write(reason)  -- optional
handle:close(reason)           -- mandatory
```

For a concrete `HostHandle`, this callback set is the capability record: there is no second Boolean capability table to keep in agreement. `supports(name)` reports whether the corresponding callback exists; readiness is intrinsic.

`read` and `write` must be non-blocking. Facility-supplied offer pulls are
stricter: they are bounded, non-yielding callbacks which receive the registered
handle explicitly and may perform one authoritative host interaction. They may
not perform Fibers operations or spawn work. Readiness is only a hint. The reactor
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

Regular files may block despite appearing ready. Their private completion-driven
driver therefore performs host calls outside search while using the same Flow
reservations and leases as the readiness-driven Reactor.


## Reactor-owned host offers

The indexed host reactor converts readiness hints into bounded, host-owned
results for operations whose authoritative syscall is irreversible. The current
sources cover accepted connections, one-shot connection and process-exit
completion, and received datagrams.

### Semantic boundary

Offers and terminal states enter Fibers as external facts through `EventQueue`
and `Signal`. They are not produced by an ordinary Fibers task: such a task would
remain a possible transactional supplier and could lawfully suppress certified
fallback.

A source therefore has this shape:

```text
readiness hint
    ↓
reserve bounded source capacity
    ↓
authoritative non-blocking host call
    ↓
publish a host-owned external offer
    ↓
committed claim returns capacity and reactor demand
```

Readiness remains only a hint. `would_block` returns reserved capacity and rearms
the source. Once one value has been obtained, recurring sources probe until they
reach `would_block` or exhaust capacity, so an edge-clearing backend cannot strand
already-buffered accepts or packets.

The pull callback is a bounded, non-yielding reactor callback. It receives the
registered handle explicitly and may perform one authoritative host interaction;
it may not perform Fibers operations, spawn work or yield directly. A violation
retires that source as a host protocol failure without suspending the shared
reactor.

### Ownership

The source is a Lifetime. Unclaimed results remain accountable to it until a committed `next_op()`
transfers or consumes them. Accepted descriptors enter a
source-owned `HostHold` before publication; source retirement closes every
unclaimed descriptor. Conversion failure discards only the selected keyed hold
entry, so other queued accepted handles remain valid. Connection-attempt handles
remain under their Dial hold, and packet bytes remain in the bounded external
queue.

`next_op()` exposes only an offer. `result_op()` additionally observes source
termination. A facility uses the narrower form when it has an independent
lifecycle terminal, and the combined form when source retirement is itself the
authoritative terminal event, as for Listener acceptance and one-shot process
exit completion.

### Reactor integration

Offer entries use the same indexed poller, control queue and single reactor task
as Flow directions. Poll-only providers use the same reactor with a bounded
per-source interval rather than creating a polling task. They add no task per
source. Returning capacity selects a
deduplicated reactor-demand effect in the same committed world as consumption,
which makes backpressure and rearming one transaction. Retirement attempts
every unclaimed-value disposal, restores capacity and publishes terminal state
regardless of disposal failure; accumulated cleanup errors are then reported by
`closed_op()` and structural Closure.

The low-level host contract remains readiness-oriented. POSIX, Nixio and
simulated providers continue to supply non-blocking calls and readiness keys;
the shared reactor adapter provides the owned-offer semantics above them.

### Scope

Received datagrams use reactor-owned offers. Datagram sends remain in the socket
send driver because transferring payload custody to a host send queue requires a
separate bounded-buffer contract. This avoids generalising the offer mechanism
beyond the ownership rules it can state precisely.


## Named-connection coordination

### The race as an option algebra

One Cell machine contains the closed-family flags, globally ordered
unattempted candidates, admitted numeric Dials, stagger deadline and winner.
Each coordinator iteration describes one serial scheduling step:

```lua
local outcomes = attempt_result_ops(current)
local sources = family_completion_ops(current, query)
local progress = choice(admit_next_attempt_op(), wake_ops(current))

return outcomes:or_else(sources:or_else(progress))
```

The ordering is semantic rather than source-order bias. A launch through
`progress` commits only with negative guards proving that no attempt outcome or
DNS completion was ready in the same world. Consequently, a connection which
succeeds at the exact stagger deadline suppresses a second launch.

Candidate admission composes the Cell selection, `socket.dial_op` admission
and the active-attempt state update in one option. The transaction allocates no
file descriptor speculatively: the numeric Dial starts its non-blocking socket
work only after admission commits. Each numeric attempt exposes its definitive
connect result as a one-shot reactor-owned external offer. Attempt completion
then combines the Dial's custody transfer with the winner or failure state
transition. Because completion is an observed external fact rather than a
future task supplier, a result already visible at the stagger or attempt deadline
correctly defeats the fallback timer.

The public facility is the ordinary `Dial`; Happy Eyeballs is the strategy selected
for a name endpoint. Its implementation lives under `fibers.socket.dial.named`,
with the transactional coordinator in `fibers.socket.dial.named.state`. These are
socket-subsystem implementation modules rather than runtime internals.

### One Dial type under custody

`socket.dial_op` admits the ordinary `Dial` Lifetime and selects the named strategy from the endpoint kind:

```lua
local dial = fibers.perform(socket.dial_op(socket.name_endpoint('example.org', 443)))
local connection, report = dial:connect()
assert(connection, report)
```

`dial:connect()` is the direct launch-and-collection convenience. It returns
only after the winner has moved into the target scope and the private race has
closed. The lower-level lifecycle remains selectable:

```lua
local connection, err = fibers.perform(dial:result_op(target_scope))
local report = fibers.perform(dial:report_op())
local closed, close_err = fibers.perform(dial:closed_op())
```

`connected_op` is success-only. `failed_op` observes terminal failure.
`result_op` combines them through certified fallback. A successful connection
which has not yet been collected remains in the Dial's private Scope custody.
Closing the Dial cancels resolution and every outstanding numeric Dial.

There is deliberately no `connect_op`. Starting the private driver is a
committed effect; its later connection result cannot be required by the same
transaction which admits that driver. The public split is therefore the same as
other effectful facilities: an option admits the handle under custody, then its result
operations participate in subsequent choices.

### Resolver integration

The named strategy consumes `Query:family_finished_op` independently for `inet6`
and `inet4`. It does not wait for the resolver's combined terminal list.
Candidates therefore remain dynamic, including addresses which arrive after one
or more connection attempts have started.

An explicit resolver can be supplied:

```lua
local resolver = socket.dns_resolver({
  nameservers = {
    socket.ipv4_address('192.0.2.53', 53),
  },
})

local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  resolver = resolver,
})
```

The DNS selection options accepted by `socket.resolve_name` are also accepted by
`socket.connect` for a name endpoint: `dns` and `nameservers` through
`resolver_options`.

### Scope and custody guarantee

The internal custody tree is:

```text
Dial (strategy: happy_eyeballs_v2)
└── private driver scope
    ├── resolver Query
    ├── numeric Dial 1
    ├── numeric Dial 2
    └── selected Stream, until collected
```

The winning numeric Dial first moves its Stream into the private driver scope.
Collecting the Dial result then moves that Stream into the caller's target
scope. Every other resource remains in the private tree and is closed through
ordinary Closure. This prevents a late successful attempt from leaking a
socket after another attempt has already won.
