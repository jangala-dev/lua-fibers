# External-resource invariants

This document specifies the trusted substrate shared by pipes, Streams, stream
sockets, datagrams, processes and future regular-file facilities.

## Host actions occur after commitment

Options may describe acquisition, admission, custody movement, closure requests
and readiness observations. They must not create, accept, connect, read, write or
close host objects while an option is being searched.

A committed driver task performs the authoritative host action. Readiness is
only a hint that such an action may make progress; `read`, `write`, `accept` and
`finish_connect` may still return `would_block`.

## Continuous handle coverage

Every acquired host handle follows this lifecycle:

```text
created -> adopted -> owned -> closing -> closed
```

`adopted` means that a pre-admitted adoption record covers the handle before the
acquiring fibre may yield. `owned` means that a Stream, Listener, Dial or other
structural resource has taken responsibility for it. Failed partial
construction closes every handle which remains in an adoption record.

A handle must never have two structural owners. Moving a handle from an
adoption record to a resource is a transfer, not a second admission.

## Reactor registrations

Each readiness-driven Stream direction owns one reactor registration:

```text
created -> registered -> retired
```

Registration identity contains a generation. A readiness delivery for an older
generation is stale and cannot invoke the backend. Retirement removes the
registration from the indexed poller before its resource can settle.

The reactor performs bounded work:

- `read_quantum` bounds one read service;
- `write_quantum` bounds one write service;
- `control_quantum` bounds control messages drained before returning to ready
  work;
- `would_block` disarms the registration until readiness is delivered again.

No fairness stronger than bounded service and repeated queue progress is
currently promised. Host backends must not depend on source order among ready
registrations.

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
- the Stream's owned subtree is ready to settle.

`shutdown_read_op` and `shutdown_write_op` are directional. Graceful write
shutdown first permits already admitted bytes to drain. Abortive closure may
retire queued work immediately.

A peer read shutdown is error-ready for a writer: the next authoritative write
must run and report `broken_pipe`, rather than waiting forever for successful
writability.

## Process ownership and reaping

A Process is an owned external-resource tree:

```text
Process
├── host process handle
├── supervisor task
├── launch adoption bundle
├── generated standard Streams
├── optional Stream bridge tasks
└── cached terminal status
```

Process creation uses an exec-error handshake. A successful fork is not a
successful `Command:start`; the child must complete working-directory,
environment, session, process-group, descriptor and exec setup. Every failure
path closes partial pipes and reaps the failed child before returning.

The supervisor is the single authority for signal delivery, exit observation
and reaping. These invariants apply:

- every child handle is adopted before the acquiring driver may yield;
- a returned Process has exactly one reap authority;
- `result_op` becomes ready only after exactly-once reaping;
- repeated result observations return the same tagged status;
- scope settlement cannot finish successfully while it owns an unreaped child;
- generated pipe Streams remain beneath the Process driver scope;
- supplied Streams are borrowed and bridged rather than silently taken;
- `closed_op` proves settlement of the host handle, Streams, bridges and driver.

Native bindings should use a stable process identity, such as a pidfd, where
available. A fallback process strategy must serialise signal and reap decisions so a
reused numeric PID cannot be targeted after the owned child has terminated.

`communicate` is deliberately a direct post-commit procedure. External input
must be delivered before child exit can be observed, so it cannot truthfully be
represented as one speculative all-or-nothing option. Capture readers run
concurrently, and a capture error requests Process closure before returning.

`Command:launch_op` is different: a guard constructs a fresh Process during the
current synchronisation attempt, while a committed supervisor-spawn effect
performs the irreversible launch afterwards. The option means that ownership of
a launch attempt has committed; `Process:launch_result_op` observes the later
exec handshake.

## Runtime inspection

The audit is observational and does not affect production semantics. It uses
weak references so inspection cannot retain resources.

```lua
local snapshot = runtime:io_audit_snapshot({
  include_history = true,
})

runtime:assert_io_quiescent('after server shutdown')
```

The snapshot reports live handle and registration states, close attempts,
service counts, lifecycle violations and aggregate reactor statistics. A clean
runtime has no live handles, no live registrations and no recorded ownership
violations.

The reactor also exposes:

```lua
local snapshot = runtime.host_reactor:snapshot()
runtime.host_reactor:assert_quiescent('after shutdown')
```

These methods are intended for tests, embedders and diagnostics. The underlying
`fibers.diagnostics.io` module remains internal.

## Host contract

Every host declares socket support explicitly:

```lua
host.capabilities.socket
host.capabilities.socket_ipv4
host.capabilities.socket_ipv6
host.capabilities.socket_unix
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
- complete handle, task and registration settlement.
