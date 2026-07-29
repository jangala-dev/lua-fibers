# Reactor-owned host offers

The indexed host reactor converts readiness hints into bounded, host-owned
results for operations whose authoritative syscall is irreversible. The current
sources cover accepted connections, one-shot connection and process-exit
completion, and received datagrams.

## Semantic boundary

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

## Ownership

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

## Reactor integration

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

## Scope

Received datagrams use reactor-owned offers. Datagram sends remain in the socket
send driver because transferring payload custody to a host send queue requires a
separate bounded-buffer contract. This avoids generalising the offer mechanism
beyond the ownership rules it can state precisely.
