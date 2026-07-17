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

Convenience address constructors and option forms are available for internet
and Unix-domain sockets:

```lua
socket.inet_address(host, port)
socket.unix_address(path)

socket.listen_inet_op(host, port, opts)
socket.listen_unix_op(path, opts)
socket.dial_inet_op(host, port, opts)
socket.dial_unix_op(path, opts)
```

Source binding fields from the earlier API remain accepted by
`dial_inet_op`:

```lua
{
  bind_host = '127.0.0.1',
  bind_port = 0,
}
```

## Ownership and host support

Newly acquired handles are covered by pre-admitted adoption records before any
fibre can yield. Accepted and dialled Streams remain in driver scopes until a
caller commits their custody transfer. Listener and Dial drivers are structural children of their resource roots.
Resource settlement therefore cancels and joins them before releasing the root,
while readiness and bounded-queue waits remain cancellable.

The deterministic `ManualHost` implements pipes and virtual sockets for tests,
examples and embedding work. Native pipe support is present in the available
POSIX host families. Native listener and dial capabilities remain the next host
adapter milestone; unsupported hosts return structured `unsupported` errors
rather than failing by module load order.

Regular files and processes require additional host-job and supervision layers.
They should not be implemented by treating regular descriptors as safely
non-blocking readiness resources.
