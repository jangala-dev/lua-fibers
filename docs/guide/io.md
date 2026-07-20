# Pipes and sockets

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
filters. Verified LuaJIT/cffi Linux hosts may provide `getaddrinfo` as an
initial blocking resolver capability and advertise `resolver_blocking = true`.
Compatibility FFI providers which cannot safely traverse `getaddrinfo` results
leave the resolver capability disabled. Embedders which cannot allow resolver
calls on the runtime thread should replace it with a worker-backed or native
asynchronous resolver.

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

local udp = socket.datagram_ipv4('0.0.0.0', 0, {
  receive_capacity = 64,
  send_capacity = 64,
})

-- Equivalent composable construction:
-- local udp = fibers.perform(socket.datagram_ipv4_op('0.0.0.0', 0))
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
