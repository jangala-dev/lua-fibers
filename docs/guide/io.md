# Files, pipes, processes and sockets

This guide is application-facing. It assumes the option and lifetime rules in [Options](options.md) and [Lifetimes](lifetimes.md); reactor and handle invariants are kept in [I/O design](../design/io.md).

Fibers restores the practical shape of the earlier I/O layer while retaining
version 1 custody and option semantics.

## Evented regular files

Regular files are completion-driven rather than readiness-driven: polling a
regular descriptor does not prove that storage or filesystem work will complete
without waiting. Fibers therefore keeps host file calls in a private file-driver
Lifetime. The byte plane is nevertheless the same one used by Streams and
sockets: bounded `Flow` state sits between the application and the host driver.

```text
                          Flow byte plane

application reads  <---  RX Flow  <--- host read driver
application writes --->  TX Flow  ---> host write driver
```

Sockets service the same Flow reservation/lease protocol from readiness events;
regular files service it from completion-driven provider calls. Once bytes reach
a Flow, the transactional semantics are identical.

File operations require an active runtime:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local file = require('fibers.file')
local AutoIO = require('fibers.io.auto')

fibers.run(function()
  local resolv_conf, err = file.read_all('/etc/resolv.conf', {
    max = 64 * 1024,
  })
  assert(resolv_conf, err)
end, { host = AutoIO.default() })
```

`RegularFile:read_op(n)` is a single transactional byte decision. It consumes
already published RX bytes, or becomes ready at logical EOF. It does not commit
merely because a host read was submitted. A timeout therefore races actual byte
availability:

```lua
local which, value = fibers.perform(Op.named_choice({
  bytes = f:read_op(4096),
  timeout = Sleep.sleep_op(1),
}))
```

`read_some_op(n)` is the Stream-style name for the same operation; `read_op(n)`
is retained as the ordinary file spelling. `read_exactly_op` and `read_all_op`
remain one transactional byte decision: if a finite read-ahead Flow cannot hold
the fact required by that atomic operation they report a capacity error without
consuming buffered bytes. The direct `read_exactly` and bounded `read_all` methods
use the same shared procedural byte layer as Streams and may perform several
`read_some_op` decisions. Fibers therefore never makes a buffer unbounded merely
to pretend that a multi-decision protocol is one transaction.

Writes follow the corresponding TX law. `write_op(bytes)` and `write_all_op(bytes)`
mean that the file Lifetime has transactionally accepted responsibility for all
of `bytes`; an atomic request larger than finite TX capacity reports a capacity
error. The direct `write_all(bytes)` procedure chunks larger values through
repeated admissions. `write_some_op` accepts as much as the current Flow capacity
permits. `flush_op()` is the
settlement barrier: it waits until every byte accepted before that command has
reached the provider, then performs the provider flush operation. `sync_op()`
adds the requested storage synchronisation boundary.

```lua
local f = assert(file.open('/tmp/example', 'w+b'))
assert(f:write('data') == 4)   -- responsibility transferred to f
assert(f:flush())              -- accepted bytes reached the provider
assert(f:seek('set', 0) == 0)
assert(f:read_exactly(4) == 'data')
assert(f:sync())
assert(f:close())
```

Read-ahead does not redefine the file cursor. The RegularFile tracks buffered
read-ahead independently from the provider's host cursor. A seek or write
transactionally invalidates incompatible buffered bytes and advances a read
generation; stale in-flight prefetch is discarded. Before the next cursor-
sensitive host action, the driver reconciles any read-ahead debt. Thus `seek
("cur", ...)` is relative to bytes actually consumed by the application, not to
how far the provider happened to prefetch.

Detached admission remains explicit, but there is no data-plane File Request.
Static path jobs such as `submit_read_all_op` return a `File.Job`. Open admission
returns the admitted `RegularFile`. Cursor/durability controls such as
`submit_seek_op`, `submit_flush_op`, `submit_sync_op` and `submit_rename_op`
return a `File.Command`; its completion is selectable through `result_op()`.
Ordinary reads and writes transact directly on the byte plane.

The surface includes bounded `read_all`, `write_all`, `open`, `tmpfile`,
`rename`, `unlink`, `mkdir` and `mkdir_p`. Open files support `read`/`read_some`,
`read_exactly`, `read_line`, bounded `read_all`, `write`/`write_some`, `seek`,
`flush`, `sync`, `rename`, `filename` and `close`.

Temporary files are created with exclusive naming and default permissions of
`0600`. They are unlinked automatically when closed. Renaming one publishes it
and disables automatic unlinking:

```lua
local temporary = assert(file.tmpfile({ directory='/tmp', prefix='result-' }))
assert(temporary:write('complete'))
assert(temporary:rename('/tmp/result.txt'))
assert(temporary:close())
```

On Linux FFI hosts Fibers probes `io_uring` and uses it when the complete ring
can be established. POSIX AIO availability is also reported, but POSIX AIO
cannot by itself make `open`, path mutation and `close` asynchronous; when
`io_uring` is unavailable the complete fallback is an evented helper-process
provider. Luaposix and Nixio use the same helper protocol over their evented
process pipes.

## Pipes

`file.pipe_op()` describes acquisition of an anonymous pipe. Constructing the
option creates no host handles. Once it commits, the result is the familiar pair
of directional Streams:

```lua
local file = require('fibers.file')

local reader, writer, err = file.pipe()
assert(reader, err)

-- Equivalent composable acquisition:
-- local reader, writer, err = fibers.perform(file.pipe_op())
```

The writer produces graceful EOF when closed:

```lua
writer:write('hello')
writer:close('complete')

local bytes = reader:read_all({ max = 4096 })
reader:close('complete')
```

Internally, private host holds cover both handles until their Streams are
admitted and take custody. Public callers receive the two Streams directly.

## Stream operations

Streams expose one explicit operation per read contract:

```lua
stream:read_some_op(4096)
stream:read_exactly_op(16)
stream:read_line_op({ max = 8192 })
stream:read_all_op({ max = 1024 * 1024 })
stream:write_op('hello', ' ', 'world')
stream:write_all_op('atomic bytes')
stream:flush_op()
stream:close_op()
```

There is deliberately no Lua-file-style `read`/`read_op` compatibility shim.
Choosing `read_some`, `read_exactly`, `read_line` or `read_all` states the byte
contract at the call site. The `_op` forms remain one transactional byte fact;
the direct `read_exactly`, `read_all` and `write_all` conveniences may compose
several such facts when a bounded Stream is smaller than the requested protocol.

## Processes

`fibers.process` separates a captured command specification from the running
Process Lifetime. A Process is one Lifetime shared by its domain, Task and
private Scope views; pidfd, status-pipe and polling exit strategies sit beneath
one validated provider boundary:

```lua
local process = require('fibers.process')

local command = process.command({
  'sh', '-c', 'printf hello',
  stdin = 'null',
  stdout = 'pipe',
  stderr = 'pipe',
})

local proc, start_err = command:start()
assert(proc, start_err)
local result, communicate_err = proc:communicate({
  stdout_limit = 1024 * 1024,
  stderr_limit = 1024 * 1024,
})
assert(result, communicate_err)
```

A Command is pure and reusable. Builder methods return new values:

```lua
local base = process.command('worker', '--once')
local configured = base
  :with_stdout('pipe')
  :with_stderr('pipe')
  :with_env({ MODE = 'capture' })
```

Starting is deliberately divided into launch admission, launch observation,
and eventual process result. `launch_op()` is a true option: a guard constructs
a fresh Process at synchronisation time, admission and the supervisor spawn
effect commit together, and the option returns without implying that `exec` has
finished. If the launch branch loses, no child is created.

```lua
local proc = fibers.perform(command:launch_op())

local launched, launch_err = fibers.perform(Op.choice(
  proc:launch_result_op(),
  Sleep.sleep_op(1):map(function()
    return nil, { kind = 'timeout', phase = 'launch' }
  end)
))

if not launched then
  proc:close('launch timeout')
end
```

`start()` is the ordinary direct convenience. It launches, waits for the exec
handshake, and returns only a successfully launched Process or a structured
error:

```lua
local proc, err = command:start()
```

There is deliberately no `start_op()`. An option cannot both initiate an
irreversible child and keep the launch handshake in transactional competition.
The split makes two different choices explicit:

```text
choice(command:launch_op(), shutdown_op)
    whether a launch should exist

choice(proc:launch_result_op(), timeout_op)
    how long to wait for that launch Lifetime
```

A timeout is caller policy; it is not confused with child-process failure.
`result_op()` becomes ready only after the child has reached a terminal state
and has been reaped exactly once. Normal outcomes are tagged values:

```lua
{ kind = 'exited', code = 0, success = true }
{ kind = 'exited', code = 7, success = false }
{ kind = 'signalled', signal = 15, signal_name = 'TERM', success = false }
```

Generated standard streams are ordinary Fibers Streams:

```lua
local proc = assert(process.command({
  'filter',
  stdin = 'pipe',
  stdout = 'pipe',
  stderr = 'pipe',
}):start())

proc:stdin():write('input')
proc:stdin():close('input complete')
local output = proc:stdout():read_all({ max = 1024 * 1024 })
local status = proc:result()
```

The accepted standard-stream forms are:

```text
stdin:   inherit | null | pipe | Stream
stdout:  inherit | null | pipe | Stream
stderr:  inherit | null | pipe | stdout | Stream
```

A supplied Stream is bridged through a pipe held by the Process Lifetime. It need not expose a
file descriptor, and it remains in its caller's custody. `process.redirect` can
request flushing or closure of the destination after the bridge finishes.

`communicate()` is a committed, single-use procedure rather than an option. It
writes and closes stdin, drains stdout and stderr concurrently, waits for the
reaped status, and enforces explicit output limits. Output-collection failure begins
structural Process Closure so a child cannot remain blocked on unconsumed
output.

```lua
local result = proc:communicate({
  input = request,
  stdout_limit = 4 * 1024 * 1024,
  stderr_limit = 1024 * 1024,
})
```

Process requests and completed Closure are distinct:

```lua
proc:terminate_op() -- commit the configured graceful signal request
proc:kill_op()      -- commit the configured forceful signal request
proc:request_close_op(reason)
proc:closed_op()
```

The direct `terminate()`, `kill()` and `signal()` methods perform their request
options. `close(reason)` performs `request_close_op(reason)` and then waits for
`closed_op()`. The supervisor closes stdin, waits for the grace interval,
escalates where necessary, observes the reactor-owned exit completion, and
finishes its Streams and supervisor Task. Scope Closure invokes the same
protocol, and inability to signal, reap or close remains visible in the scope
report.

Commands which may create descendants should normally request a new process
group and target that group during shutdown:

```lua
process.command({
  'sh', '-c', script,
  process_group = 'new',
  shutdown = { target = 'group', grace = 1.0 },
})
```

The test-only SimulatedHost, Linux FFI hosts and luaposix host implement the
full version 1 process contract. Nixio supplies evented child processes through
a per-command reaper and status pipe. It supports ordinary stdio, environment,
working-directory, session, signalling and reaping behaviour, but advertises
four narrower guarantees:

```text
process_exec_proof = false
process_pass_fds = false
process_close_fds = "known"
process_groups = "session"
```

Nixio preflights executable and working-directory failures and reports child
setup failures before returning a Process. It cannot prove the final exec
transition without close-on-exec, cannot retain arbitrary passed descriptors,
and implements `process_group = "new"` by creating a new session. Requests for
numeric process groups or non-empty `pass_fds` return structured `unsupported`
errors.

Fibers does not create a new process group silently because terminal and job-control
semantics may depend on the inherited group.

## Listeners and connections

Socket acquisition is split into familiar resource types. Address and option
tables are snapshotted when an option is constructed, so later caller mutation
does not change the meaning of an inert option.


```text
Listener   accepts connected Streams
Dial       represents an admitted outbound attempt
Connection is a duplex Stream
```

Listening remains concise:

```lua
local socket = require('fibers.socket')

local listener, err = socket.listen_inet('127.0.0.1', 8080)
assert(listener, err)

local connection, accept_err = listener:accept()
assert(connection, accept_err)
```

Accepted connections expose the ordinary Stream surface directly. Before
acceptance they remain in the Listener Lifetime's private Scope custody. `accept_op`
dequeues a connection and moves its complete Stream subtree into the accepting
scope in the same commit. If the option loses a choice, neither action occurs.
Queued input has certified priority over terminal listener closure. When a
transfer option will be stored or performed by another fiber, pass its target Scope explicitly. Direct methods use the current Scope when
the target is omitted; inert operation constructors require the target explicitly.

Outbound connection establishment is deliberately two-stage:

```lua
local dial = socket.dial(socket.inet_address('127.0.0.1', 8080))
local connection, err = dial:result()

-- Explicit composable form:
local selected_dial = fibers.perform(socket.dial_op(socket.inet_address('127.0.0.1', 8080)))
local selected, selected_err = fibers.perform(selected_dial:result_op(fibers.current_scope()))
```

The split allows the eventual connection result to participate correctly in
`choice`, timeouts and Happy Eyeballs races.
`dial:connected_op(fibers.current_scope())` is a success-only option and becomes refutable after terminal failure or closure. A
successful but untaken connection remains in the Dial Lifetime's private Scope custody;
claiming it moves the complete Stream subtree into the caller's scope. As with
`accept_op`, pass an explicit target when a result option is intended for a
different fiber or scope.
`dial:result_op(fibers.current_scope())` returns either the transferred connection or its structured
error. `dial:closed_op()` observes execution termination and completed custody
disposition.

Listener and Dial lifecycle state is explicit transactional state rather than a
collection of completion flags and mutable booleans. The principal states are:

```text
Listener: starting -> active -> stopping -> stopped
Dial:     starting -> connected -> taken
          |             |
          +-> failed    +-> closing -> closed
          +----------------^
```

A close option commits the lifecycle transition and the Lifetime execution interrupt
effect in the same world. Host closure then occurs in participant-local
post-commit code. A Dial take commits its `connected -> taken` transition and
the Stream custody move together, so neither can occur without the other.
Expected host failures are stored in lifecycle state as values; adapter defects
and close failures are marked fatal and remain visible during Scope Closure.

Numeric address constructors are explicit:

```lua
socket.ipv4_address('127.0.0.1', 8080)
socket.ipv6_address('::1', 8080, { scope_id = 0 })
socket.unix_address('/run/example.sock')
```

`socket.inet_address` remains a convenience classifier. Numeric input produces
an IPv4 or IPv6 address; a host name produces an unresolved name endpoint.
Native socket creation accepts only numeric or Unix addresses.

```lua
local endpoint = socket.name_endpoint('example.org', 443)
local query = socket.resolve(endpoint)
local addresses, resolve_err = query:result()
assert(addresses, resolve_err)

local dial = socket.dial(addresses[1])
local connection, dial_err = dial:result()
```

Resolution is deliberately two-stage. `socket.resolve_op` admits a query Lifetime
and starts its driver after commitment. `query:addresses_op()` is success-only
and becomes refutable after terminal failure; `query:result_op()` combines it
with the failure result through certified fallback. A and AAAA completion is
also published independently through `query:family_addresses_op(family)` and
`query:family_finished_op(family)`. This leaves the query alive as two dynamic,
explicitly closed address sources for Happy Eyeballs coordination rather than
hiding DNS inside one blocking dial call.

Fibers includes a DNS stub resolver implemented over its own non-blocking UDP,
TCP, timers and task scopes. It sends recursive-desired A and AAAA questions to
configured recursive name servers, validates replies, follows bounded CNAME
chains, caches positive and negative answers, retries alternate servers and
falls back to DNS-over-TCP when UDP is truncated. It never calls `getaddrinfo`.

```lua
local resolver = socket.dns_resolver({
  nameservers = {
    socket.ipv4_address('192.0.2.53', 53),
    socket.ipv6_address('2001:db8::53', 53),
  },
})

local query = socket.resolve_name('example.org', 443, {
  resolver = resolver,
})
```

When a native host advertises only a blocking resolver but supplies Fibers
stream and datagram sockets, `socket.resolve` prefers the DNS implementation.
An explicit `resolver`, `dns = true`, or `nameservers` option also
selects it. The host resolver remains available when selected explicitly or when the host
does not provide the socket capabilities needed by the Fibers DNS resolver. Missing
DNS configuration is otherwise reported as an error.

The default DNS configuration is read from `/etc/resolv.conf`, local static
names are read from `/etc/hosts`, and transaction-id entropy may be read from
`/dev/urandom`. All three use the evented `fibers.file` provider rather than
synchronous Lua file handles. Secure transaction-id entropy is required by
default; embedded applications should normally supply name-server addresses,
host records and secure entropy explicitly. The DNS cache is bounded by
`maximum_cache_entries`, which defaults to 1024. Services
must presently be numeric ports; DNS does not provide the `/etc/services` part
of `getaddrinfo`.
The resolver is a stub resolver, not an iterative recursive resolver, and does
not yet validate DNSSEC.

Named connections use the two independently closed family results directly:

```lua
local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  resolver = resolver,
  resolution_delay = 0.050,
  attempt_delay = 0.250,
  maximum_candidates = 64,
  -- maximum_active_attempts defaults to maximum_candidates
  -- maximum_active_attempts = 4, -- bounded-host override
  -- attempt_timeout = 2.0,
})
assert(connection, report)
```

`socket.connect` on a name endpoint implements the Happy Eyeballs v2 coordination loop as a
Machine. Attempt outcomes, DNS completions and timer/admission
progress are composed as `outcomes:or_else(sources:or_else(progress))`. New
addresses may join the globally ordered unattempted set after numeric Dials have
begun. A host or application global destination-ordering policy is required by
default; `destination_ordering = 'stable'` is the explicit portable non-RFC
fallback. The general profile does not impose a second four-attempt cap:
`maximum_active_attempts` defaults to `maximum_candidates`. Constrained profiles
may lower it and use `attempt_timeout` to release slots held by black-holed
connections. The first successful Stream moves into the caller's scope, and the
call returns only after
the private race has closed every losing query, Dial and Stream. Use `socket.dial_op` when admission itself must participate in a choice, then
select from the returned `Dial` lifecycle. The following sections give the complete connection policy and reporting contract.

The general entry points dispatch by endpoint kind:

```lua
socket.dial_op(endpoint, opts)
socket.dial(endpoint, opts)
socket.connect(endpoint, opts)
```

Convenience forms include:

```lua
socket.listen_ipv4_op(host, port, opts)
socket.listen_ipv6_op(host, port, opts)
socket.listen_unix_op(path, opts)

socket.dial_op(socket.ipv4_address(host, port), opts)
socket.dial_op(socket.ipv6_address(host, port), opts)
socket.dial_op(socket.unix_address(path), opts)

socket.resolve_name_op(host, service, opts)
socket.dial_op(socket.name_endpoint(host, service), opts)
```

Source binding is explicit through a numeric address:

```lua
{
  local_address = socket.ipv4_address('127.0.0.1', 0),
}
```


### Resolver protocol and selection

The public resolution surface above is backed by the following complete resolver contract.

### Implemented protocol behaviour

The resolver currently provides:

- concurrent A and AAAA questions;
- strict transaction id, peer, question, class and type validation;
- an EDNS(0) UDP payload advertisement, defaulting to 1232 octets;
- retries across configured recursive servers before the next attempt round;
- DNS-over-TCP fallback for truncated UDP responses;
- bounded CNAME following and loop detection;
- positive RRset caching and SOA-derived negative caching;
- `/etc/resolv.conf` name-server, search, timeout, attempts and `ndots` parsing;
- `/etc/hosts` lookup before DNS;
- secure transaction-id entropy from an injected callback or `/dev/urandom`;
- a bounded positive and negative cache, defaulting to 1024 entries;
- deterministic explicit configuration for embedded and ManualHost use.

Input decoding is bounded by message size, record count, label length, expanded
name length and compression-pointer depth. Malformed or unrelated datagrams are
discarded while the transaction deadline remains open.

Resolver configuration, hosts data and `/dev/urandom` are read through
`fibers.file`; the DNS path does not call `io.open`. A small Cell once-gate
serialises each lazy file load, so concurrent A and AAAA producers share one
non-blocking read and cancellation reopens an unfinished load.

Transaction ids are taken from an injected `random_u16` callback when supplied,
then from `/dev/urandom` through `fibers.file`. Resolution fails by default when
neither secure source is available. A process-local weak fallback exists only
for constrained or deterministic environments which explicitly set
`allow_weak_random = true`.

`maximum_cache_entries` bounds the resolver cache and defaults to 1024. Set it
to zero to disable caching. Eviction is deterministic first-in, first-out after
expired entries have been removed.

### Selection policy

An explicit resolver always wins:

```lua
socket.resolve_name('example.org', 443, { resolver = resolver })
```

The shorthand options `dns = true` and `nameservers = {...}`
construct a resolver for that query. Where a native host advertises
`resolver_blocking = true` and provides both datagram and stream sockets, the
socket resolver creates one DNS resolver per Runtime and reuses its cache.

If automatic DNS configuration is unavailable, resolution returns a configuration
error. Supply an explicit resolver where the host resolver is required.

### Deliberate limits

This is a stub resolver which depends on a configured recursive server. It does
not perform iterative recursion, DNSSEC validation, mDNS, LLMNR, DNS over TLS or
DNS over HTTPS. It currently resolves numeric service ports only. Address
ordering and connection racing remain responsibilities of
[`socket.connect`](io.md#named-connection-policy) rather than the DNS layer.

### Named-connection policy

Named connections use Happy Eyeballs coordination over the independently closing A and AAAA result streams. The following options and reports form the public application contract.

### Candidate policy

Every new family completion is merged with the current unattempted set. A
single global destination-ordering policy then ranks all currently available
IPv4 and IPv6 destinations before family interleaving. The first address in
that global order determines the initially preferred family; it is not fixed to
IPv6.

Routing and source-address-sensitive RFC 6724 policy is injected rather than
guessed by the coordinator:

```lua
local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  order_destinations = function(addresses, endpoint, opts)
    return application_destination_order(addresses, endpoint, opts)
  end,
})
```

A host may instead provide `sort_destination_addresses`. One of these global
policies is required by default: the coordinator does not invent a portable
RFC 6724 ranking from address family alone. A host which cannot supply routing
and source-address-aware ordering may opt in explicitly to stable resolver
order:

```lua
local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  destination_ordering = 'stable',
})
```

This is reported as `destination_ordering = 'stable'` and is an intentional
non-RFC fallback, not an implicit claim of RFC 6724 compliance.

Ordering callbacks participate in guarded option construction. They therefore
must be immediate, deterministic, non-yielding and side-effect free. Fibers
passes an isolated copy in stable arrival/current-policy order and validates
that the returned list contains only known destinations; omitted destinations
are appended rather than discarded. Stable input order remains available as the
final RFC 6724 tie-break.

After global ordering, `first_family_count` controls how many addresses from the
initially preferred family may be launched before ordinary alternation. The
default is one. Later DNS results re-order only the unattempted set; Dials which
have already begun continue unchanged.

### Timing and connection options

The principal options are:

```lua
{
  resolution_delay = 0.050,
  attempt_delay = 0.250, -- minimum 0.010
  first_family_count = 1,
  timeout = 10.0,
  -- timeout = false, -- disable the deadline
  -- deadline = absolute_monotonic_time,
  maximum_candidates = 64,
  -- By default maximum_active_attempts equals maximum_candidates.
  -- maximum_active_attempts = 4, -- explicit bounded-host profile
  -- attempt_timeout = 2.0,       -- releases a bounded slot after this interval

  nodelay = true,
  local_address_inet6 = socket.ipv6_address('::', 0),
  local_address_inet4 = socket.ipv4_address('0.0.0.0', 0),

  resolver = resolver,
  resolver_options = {},
}
```

A relative `timeout` begins when the admitted Dial driver starts and defaults to
30 seconds when omitted. Set `timeout = false` to disable it. An absolute `deadline` uses the Runtime's monotonic clock. RFC
8305's 10 millisecond minimum connection-attempt delay is enforced.

`maximum_candidates` bounds retained DNS destinations and defaults to 64; the
report records any dropped candidates. In the general profile,
`maximum_active_attempts` defaults to that same bound, so a black-holed earlier
connection does not prevent later candidates from being launched at their
stagger times merely because four attempts are already pending. A constrained
host may set a smaller explicit bound.

A smaller active-attempt bound is an explicit resource/liveness trade-off. Use
`attempt_timeout` to give every numeric Dial an absolute per-attempt deadline; a
timed-out Dial fails, closes and releases its slot so the next candidate can be
admitted. Without an attempt timeout, a full set of black-holed attempts may
hold every slot until the overall deadline. Reports expose
`capacity_limited`, `unattempted_count`, `active_attempts` and
`blocked_by_attempt_capacity` so this condition is observable.

Family-specific local addresses avoid applying an IPv4 bind address to an IPv6
attempt or the reverse. Ordinary Stream capacity and chunk-size options are
forwarded to each numeric Dial.

### Reports and failures

Success returns a report alongside the Stream:

```lua
{
  kind = 'dial',
  strategy = 'happy_eyeballs_v2',
  status = 'connected',
  destination_ordering = 'host',
  maximum_candidates = 64,
  maximum_active_attempts = 64,
  capacity_limited = false,
  winner = {
    address = address,
    family = 'inet6',
    attempt = 1,
  },
  attempts = {
    {
      address = address,
      family = 'inet6',
      status = 'succeeded',
      started_at = 0.0,
      completed_at = 0.012,
    },
  },
  families = {
    inet6 = { done = true, addresses = {...} },
    inet4 = { done = false, addresses = {...} },
  },
}
```

On terminal failure, `connect` returns `nil, err`; the same report is
available as `err.report`. Individual attempt errors are retained. Resolver
errors are returned directly when no connection attempt could be made;
otherwise terminal exhaustion is reported as `connect_failed` with the attempt
history.

Reports use monotonic Runtime times. They are intended for diagnostics and
conformance tests rather than as a persistent serialisation format.

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

## Datagram sockets

Datagram sockets are message-oriented resources, not Streams. Construction is
inert until the option commits:

```lua
local socket = require('fibers.socket')

local udp = socket.udp_ipv4('0.0.0.0', 0, {
  receive_capacity = 64,
  send_capacity = 64,
})

-- Equivalent composable construction:
-- local udp = fibers.perform(socket.udp_ipv4_op('0.0.0.0', 0))
```

The ordinary surface is:

```lua
udp:send_to_op(payload, destination)
udp:receive_from_op({ max_size = 4096 })
udp:flush_op()
udp:close_op(reason)
udp:closed_op()
```

Each has the exact direct twin described in
[`options.md`](options.md). A received value is a record:

```lua
{
  data = bytes,
  peer = source_address,
  local_address = receiving_address,
  truncated = false,
  original_size = nil,
  flags = {},
}
```

`send_to_op` means that one complete datagram has been admitted to the socket's
bounded outgoing queue. It does not claim remote delivery. `flush_op` captures
a sequence watermark when it is constructed and waits until every preceding
datagram has either been accepted by the host or failed. UDP messages are
indivisible: a host which reports a partial send has violated the host contract.

`receive_from_op` claims one complete message from a bounded reactor-owned
packet source. The reactor reserves a source slot before calling `recvfrom`,
drains authoritatively until the host reports `would_block`, and disarms the
readiness registration while capacity is exhausted. Consuming a packet returns
its slot and emits fresh reactor demand in the same committed world. User-space
memory is therefore bounded before the irreversible host call. A caller may
supply a smaller `max_size`; Fibers then returns the prefix and marks the record
as truncated. Linux FFI hosts use kernel truncation reporting and preserve the
original wire size. The initial luaposix and Nixio adapters preserve datagram
boundaries but declare that exact kernel truncation metadata is unavailable
through their present APIs.

The socket owns one driver task for outgoing sends and Closure, its host handle,
a bounded send queue and the packet source. `sendto` occurs in the driver;
`recvfrom` is serviced by the Runtime's single indexed reactor. Readiness remains
a hint: either authoritative call may still return `would_block`. Closing retires
the packet source and pending sends, closes the host handle and joins the driver
before `closed_op` succeeds.

The test-only SimulatedHost can deliver, drop and truncate packets without
real timing. It is used by both semantic evaluators. Native conformance covers
IPv4 and IPv6 loopback, zero-length messages, source addresses, truncation and
repeated socket churn.

## Custody and host support

Newly acquired handles enter private host holds before any fiber can yield.
Accepted descriptors are placed in an accept-source hold before the reactor
publishes their offer; unclaimed offers remain under that source's Lifetime and
are closed during source retirement. Connected Streams remain in each Dial's
private Scope until a caller commits their custody transfer. Listener and Dial
Task, Scope and domain views share one Lifetime; no driver Task is a separate
structural child of the public root. Resource Closure requests root shutdown
before requesting its children, then joins and finishes those children before
closing the root. Readiness and bounded-offer waits remain cancellable.

The test-only `SimulatedHost` implements pipes, virtual sockets and resolver
records. `ManualHost` itself provides only deterministic time, readiness and injected final host methods.
Native pipes are available in
the existing POSIX-oriented host families. The LuaJIT/cffi Linux host family now
adds non-blocking IPv4, IPv6 and Unix stream sockets, including `accept4`
fallback, `SO_ERROR` connect completion, close-on-exec descriptors and Unix-path
cleanup. Optional native conformance tests run when those backends are available;
unsupported hosts return structured `unsupported` errors rather than failing by
module load order.

Regular files and processes require additional host-job and supervision layers.
They should not be implemented by treating regular descriptors as safely
non-blocking readiness resources.

## Connection metadata and address values

Connected Streams expose stable endpoint metadata where the provider supplies
it:

```lua
connection:local_address()
connection:peer_address()
```

Address helpers support comparison, display and port replacement without
provider-specific formatting:

```lua
socket.address_equal(a, b)
socket.format_address(address)
socket.address_is_wildcard(address)
socket.address_with_port(address, port)
```

The host capability matrix is explicit:

```lua
host:feature('socket')
host:feature('socket_ipv4')
host:feature('socket_ipv6')
host:feature('socket_unix')
```

A disabled family returns a structured `unsupported` error. A provider which
enables a family is expected to pass the same listener, Dial, transfer, address
metadata and Closure contract as `ManualHost`.

## I/O qualification

The public I/O model exposes domain operations rather than a second live-state inspection system. Provider and reactor invariants are qualified by the executable conformance and lifecycle tests under `tests/io`, `tests/embedding` and `tests/internal`. Internal audit instrumentation may be enabled by those tests, but it is not part of the v1 application surface.

A host provider which claims a capability is expected to pass the same operation, Closure, custody and stale-readiness laws as the built-in providers.
