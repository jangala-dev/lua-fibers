# Pipes, processes and sockets

Fibers restores the practical shape of the earlier I/O layer while retaining
version 1 ownership and option semantics.

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

Internally, pre-admitted adoption records cover both handles until their
Streams take ownership. Public callers receive the two Streams directly,
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

`fibers.process` separates an immutable command specification from the owned
running Process:

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
local captured = base
  :with_stdout('pipe')
  :with_stderr('pipe')
  :with_env({ MODE = 'capture' })
```

Starting is deliberately divided into launch admission, launch observation,
and eventual process result. `launch_op()` is a true option: a guard constructs
a fresh Process at synchronisation time, admission and the supervisor spawn
effect commit together, and the option returns without claiming that `exec` has
finished. If the launch branch loses, no child is created.

```lua
local proc = fibers.perform(command:launch_op())

local launched, launch_err = fibers.perform(fibers.choice(
  proc:launch_result_op(),
  fibers.sleep_op(1):map(function()
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
    how long to wait for that owned launch
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

A supplied Stream is bridged through a Process-owned pipe. It need not expose a
file descriptor, and it remains owned by its caller. `process.redirect` can
request flushing or closure of the destination after the bridge finishes.

`communicate()` is a committed, single-use procedure rather than an option. It
writes and closes stdin, drains stdout and stderr concurrently, waits for the
reaped status, and enforces explicit capture limits. Capture failure begins
structural Process closure so a child cannot remain blocked on unconsumed
output.

```lua
local result = proc:communicate({
  input = request,
  stdout_limit = 4 * 1024 * 1024,
  stderr_limit = 1024 * 1024,
})
```

Process requests and completed settlement are distinct:

```lua
proc:terminate_op() -- commit the configured graceful signal request
proc:kill_op()      -- commit the configured forceful signal request
proc:request_close_op(reason)
proc:closed_op()
```

The direct `terminate()`, `kill()` and `signal()` methods perform their request
options. `close(reason)` performs `request_close_op(reason)` and then waits for
`closed_op()`. The supervisor closes stdin, waits for the grace interval,
escalates where necessary, reaps the child, and settles its Streams and driver
task. Scope settlement invokes the same protocol, and inability to signal, reap
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

The deterministic ManualHost, Linux FFI hosts and luaposix host implement the
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
acceptance they remain owned by the Listener's driver scope. `accept_op`
dequeues a connection and moves its complete Stream subtree into the accepting
scope in the same commit. If the option loses a choice, neither action occurs.
Queued input has certified priority over terminal listener closure. When a
transfer option will be stored or performed by another fibre, pass its target
Scope or Region explicitly; an omitted target is the current scope at option
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
`choice`, timeouts and future Happy Eyeballs races. `dial:connected_op()` is a
success-only option and becomes refutable after terminal failure or closure. A
successful but unclaimed connection remains owned by the Dial driver's scope;
claiming it moves the complete Stream subtree into the caller's scope. As with
`accept_op`, pass an explicit target when a result option is intended for a
different fibre or scope.
`dial:result_op()` returns either the transferred connection or its structured
error. `dial:closed_op()` observes driver termination and completed custody
disposition.

Listener and Dial lifecycle state is explicit transactional state rather than a
collection of completion flags and mutable booleans. The principal states are:

```text
Listener: starting -> active -> stopping -> stopped
Dial:     starting -> connected -> claimed
          |             |
          +-> failed    +-> closing -> closed
          +----------------^
```

A close option commits the lifecycle transition and the driver's interrupt
effect in the same world. Host closure then occurs in participant-local
post-commit code. A Dial claim commits its `connected -> claimed` transition and
the Stream custody move together, so neither can occur without the other.
Expected host failures are stored in lifecycle state as values; adapter defects
and close failures are marked fatal and remain visible during scope settlement.

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

Resolution is deliberately two-stage. `socket.resolve_op` admits an owned query
and starts its driver after commitment. `query:addresses_op()` is success-only
and becomes refutable after terminal failure; `query:result_op()` combines it
with the failure result through certified fallback. This shape leaves the query
alive for future Happy Eyeballs coordination rather than hiding DNS inside one
blocking dial call.

The deterministic ManualHost provides configurable records and separate family
filters. Verified LuaJIT/cffi Linux, luaposix and Nixio hosts may provide
`getaddrinfo` as a blocking resolver capability and advertise
`resolver_blocking = true`. Providers which cannot safely expose resolution
leave the capability disabled. Embedders which cannot allow resolver calls on
the runtime thread should replace it with a worker-backed or native asynchronous
resolver.

Explicit option forms include:

```lua
socket.listen_ipv4_op(host, port, opts)
socket.listen_ipv6_op(host, port, opts)
socket.listen_unix_op(path, opts)

socket.dial_ipv4_op(host, port, opts)
socket.dial_ipv6_op(host, port, opts)
socket.dial_unix_op(path, opts)

socket.resolve_name_op(host, service, opts)
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

The deterministic ManualHost can deliver, drop and truncate packets without
real timing. It is used by both semantic evaluators. Native conformance covers
IPv4 and IPv6 loopback, zero-length messages, source addresses, truncation and
repeated socket churn.

## Ownership and host support

Newly acquired handles are covered by pre-admitted adoption records before any
fibre can yield. Accepted and dialled Streams remain in driver scopes until a
caller commits their custody transfer. Listener and Dial drivers are structural children of their resource roots.
Resource settlement therefore cancels and joins them before releasing the root,
while readiness and bounded-queue waits remain cancellable.

The deterministic `ManualHost` implements pipes, virtual sockets and resolver
records for tests, examples and embedding work. Native pipes are available in
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
metadata and settlement contract as `ManualHost`.

## I/O qualification and diagnostics

Resource qualification can assert that every handle and readiness registration
has settled:

```lua
local result = fibers.try_run(main, { host = host })
assert(result.ok, result:tostring())
result.runtime:assert_io_quiescent('application shutdown')
```

For diagnostics:

```lua
local snapshot = fibers.current_runtime():io_audit_snapshot({
  include_history = true,
})
```

The audit reports live handle ownership, registration generations, close
failures, stale readiness deliveries and lifecycle violations. See
[`../advanced/io-invariants.md`](../advanced/io-invariants.md).
