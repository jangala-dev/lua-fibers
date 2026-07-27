# Files, pipes, processes and sockets

Fibers restores the practical shape of the earlier I/O layer while retaining
version 1 custody and option semantics.

## Evented regular files

Regular files are not readiness-driven: polling a regular descriptor does not
prove that storage or filesystem work will complete without waiting. Fibers
therefore executes every regular-file and path operation through an asynchronous
provider and exposes no synchronous bootstrap file API.

File operations require an active runtime:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local file = require('fibers.file')
local Host = require('fibers.host')

fibers.run(function()
  local resolv_conf, err = file.read_all('/etc/resolv.conf', {
    max = 64 * 1024,
  })
  assert(resolv_conf, err)
end, { host = Host.default() })
```

Direct methods perform their corresponding `_op`; ordinary `_op` calls yield the
operation's final value, as elsewhere in Fibers:

```lua
local contents, err = fibers.perform(
  file.read_all_op('/etc/resolv.conf', { max = 65536 })
)
```

Callers that need detached ordered admission can use the explicit `submit_*_op`
forms. These return a `File.Job` or `File.Request` held in custody, whose completion remains
selectable through `result_op()`:

```lua
local job = fibers.perform(file.submit_read_all_op('/etc/resolv.conf', { max = 65536 }))
local contents, err = fibers.perform(job:result_op())
```

`file.open()` returns a regular file held in custody. Operations on one file are
serialised in submission order:

```lua
local f = assert(file.open('/tmp/example', 'w+b'))
assert(f:write('data'))
assert(f:seek('set', 0) == 0)
assert(f:read_exactly(4) == 'data')
assert(f:flush())
assert(f:sync())
assert(f:close())
```

The surface includes bounded `read_all`, `write_all`, `open`, `tmpfile`,
`rename`, `unlink`, `mkdir` and `mkdir_p`. Open files support `read`,
`read_exactly`, `read_line`, bounded `read_all`, `write`, `seek`, `flush`,
`sync`, `rename`, `filename` and `close`.

`flush` drains provider or language-level buffering. `sync` requests storage
synchronisation and may use `fdatasync` when `data_only = true`:

```lua
assert(f:sync({ data_only = true }))
```

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
admitted and take custody. Public callers receive the two Streams directly,
matching the successful surface of the pre-version-1 library.

## Stream migration helpers

Streams retain the explicit option-building methods:

```lua
stream:read_some_op(4096)
stream:read_exactly_op(16)
stream:read_line_op({ max = 8192 })
stream:read_all_op({ max = 1024 * 1024 })
stream:write_op('hello', ' ', 'world')
stream:flush_op()
stream:close_op()
```

`read_op` supports the familiar Lua-file forms while still returning an option:

```lua
stream:read_op(128)
stream:read_op('*l')
stream:read_op('*L')
stream:read_op('*a', { max = 1024 * 1024 })
```

`*a` remains bounded deliberately.

## Processes

`fibers.process` separates an captured command specification from the running Process Lifetime. A Process is one Lifetime shared by its domain, Task and private
Scope views; direct-wait, reaper and other host strategies sit beneath one
validated provider boundary:

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
escalates where necessary, reaps the child, and finishes its Streams and driver Task. Scope Closure invokes the same protocol, and inability to signal, reap
or close remains visible in the scope report.

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
transfer option will be stored or performed by another fibre, pass its target
target Scope explicitly; an omitted target is the current scope at option
construction.

Outbound connection establishment is deliberately two-stage:

```lua
local dial = socket.dial_inet('127.0.0.1', 8080)
local connection, err = dial:result()

-- Explicit composable form:
local selected_dial = fibers.perform(socket.dial_inet_op('127.0.0.1', 8080))
local selected, selected_err = fibers.perform(selected_dial:result_op())
```

The split allows the eventual connection result to participate correctly in
`choice`, timeouts and Happy Eyeballs races. `dial:connected_op()` is a
success-only option and becomes refutable after terminal failure or closure. A
successful but untaken connection remains in the Dial Lifetime's private Scope custody;
claiming it moves the complete Stream subtree into the caller's scope. As with
`accept_op`, pass an explicit target when a result option is intended for a
different fibre or scope.
`dial:result_op()` returns either the transferred connection or its structured
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
also published independently through `query:family_ready_op(family)` and
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
An explicit `resolver`, `dns = true`, `nameservers`, or `name_server` option also
selects it. The host resolver remains available for deterministic SimulatedHost
records and as a compatibility fallback when DNS configuration is unavailable;
`require_nonblocking = true` disables that fallback.

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
local connection, report = socket.connect_name('example.org', 443, {
  resolver = resolver,
  resolution_delay = 0.050,
  attempt_delay = 0.250,
  maximum_candidates = 64,
  maximum_active_attempts = 4,
})
assert(connection, report)
```

`socket.connect_name` implements the Happy Eyeballs v2 coordination loop as a
Machine. Attempt outcomes, DNS completions and timer/admission
progress are composed as `outcomes:or_else(sources:or_else(progress))`. New
addresses may join the globally ordered unattempted set after numeric Dials have
begun. The first successful Stream moves into the caller's scope, and the call
returns only after
the private race has closed every losing query, Dial and Stream. Use
`socket.dial_name_op` when admission itself must participate in a choice, then
select from the returned `NamedDial` lifecycle. See
[`docs/guide/happy-eyeballs.md`](happy-eyeballs.md).

Explicit option forms include:

```lua
socket.listen_ipv4_op(host, port, opts)
socket.listen_ipv6_op(host, port, opts)
socket.listen_unix_op(path, opts)

socket.dial_ipv4_op(host, port, opts)
socket.dial_ipv6_op(host, port, opts)
socket.dial_unix_op(path, opts)

socket.resolve_name_op(host, service, opts)
socket.dial_name_op(host, service, opts)
```

Source binding fields from the earlier API remain accepted by the numeric dial
helpers:

```lua
{
  bind_host = '127.0.0.1',
  bind_port = 0,
}
```

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
[`direct-and-options.md`](direct-and-options.md). A received value is a record:

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

`receive_from_op` removes one complete message from a bounded incoming queue.
When that queue is full the driver stops calling `recvfrom`, bounding user-space
memory. A caller may supply a smaller `max_size`; Fibers then returns the prefix
and marks the record as truncated. Linux FFI hosts use kernel truncation
reporting and preserve the original wire size. The initial luaposix and Nixio
adapters preserve datagram boundaries but declare that exact kernel truncation
metadata is unavailable through their present APIs.

The socket owns one driver task, its host handle, both bounded queues and its
completion state. Host `sendto` and `recvfrom` calls occur only in driver fibre
phase after construction has committed. Readiness remains a hint: an
authoritative call may still return `would_block`. Closing retires pending sends,
closes the host handle and joins the driver before `closed_op` succeeds.

The test-only SimulatedHost can deliver, drop and truncate packets without
real timing. It is used by both semantic evaluators. Native conformance covers
IPv4 and IPv6 loopback, zero-length messages, source addresses, truncation and
repeated socket churn.

## Custody and host support

Newly acquired handles enter private host holds before any fibre can yield. Accepted and dialled Streams remain in each resource Lifetime's private Scope until a
caller commits their custody transfer. Listener and Dial Task, Scope and domain views share one Lifetime; no driver Task is a separate structural child of the public root.
Resource Closure requests root shutdown before requesting its children, then
joins and finishes those children before closing the root.
Readiness and bounded-queue waits remain cancellable.

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


### Datagram service fairness

Datagram drivers use a bounded read/write service policy.
`service_quantum` defaults to one, so continuously ready receive and send work
alternate after each successful host action. A larger positive integer permits
that many successful actions from the preferred direction before preference
changes.

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
host.capabilities.socket
host.capabilities.socket_ipv4
host.capabilities.socket_ipv6
host.capabilities.socket_unix
```

A disabled family returns a structured `unsupported` error. A provider which
enables a family is expected to pass the same listener, Dial, transfer, address
metadata and Closure contract as `ManualHost`.

## I/O qualification and diagnostics

Resource qualification can assert that every handle and readiness registration
has closed:

```lua
local result = fibers.try_run(main, { host = host })
assert(result.ok, result:tostring())
result.runtime:assert_io_quiescent('application shutdown')
```

For diagnostics:

```lua
local audit = fibers.current_runtime():io_audit({
  include_history = true,
})
```

The audit reports live handle custody, registration generations, close
failures, stale readiness deliveries and lifecycle violations. See
[`../advanced/io-invariants.md`](../advanced/io-invariants.md).
