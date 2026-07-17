# Pipes and sockets

Fibers restores the practical shape of the earlier I/O layer while retaining
version 1 ownership and option semantics.

## Pipes

`file.pipe_op()` describes acquisition of an anonymous pipe. Constructing the
option creates no host handles. Once it commits, the result is the familiar pair
of directional Streams:

```lua
local file = require('fibers.file')

local reader, writer, err = fibers.perform(file.pipe_op())
assert(reader, err)
```

The writer produces graceful EOF when closed:

```lua
fibers.perform(writer:write_op('hello'))
fibers.perform(writer:close_op('complete'))

local bytes = fibers.perform(reader:read_all_op({ max = 4096 }))
fibers.perform(reader:close_op('complete'))
```

Internally, a hidden Pipe root coordinates acquisition and settlement. Public
callers receive the two Streams directly, matching the successful surface of the
pre-version-1 library.

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

Socket acquisition is split into familiar resource types:

```text
Listener   accepts connected Streams
Dial       represents an admitted outbound attempt
Connection is a duplex Stream
```

Listening remains concise:

```lua
local socket = require('fibers.socket')

local listener, err = fibers.perform(
  socket.listen_inet_op('127.0.0.1', 8080)
)
assert(listener, err)

local connection, accept_err = fibers.perform(listener:accept_op())
assert(connection, accept_err)
```

Accepted connections expose the ordinary Stream surface directly.

Outbound connection establishment is deliberately two-stage:

```lua
local dial = fibers.perform(
  socket.dial_inet_op('127.0.0.1', 8080)
)

local connection, err = fibers.perform(dial:result_op())
```

The split allows the eventual connection result to participate correctly in
`choice`, timeouts and future Happy Eyeballs races. `dial:connected_op()` is a
success-only option and becomes refutable after terminal failure;
`dial:result_op()` returns either the connection or its structured error.

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
fibre can yield. Streams, listeners and dials are then settled by their owning
scope.

The deterministic `ManualHost` implements pipes and virtual sockets for tests,
examples and embedding work. Native pipe support is present in the available
POSIX host families. Native listener and dial capabilities remain the next host
adapter milestone; unsupported hosts return structured `unsupported` errors
rather than failing by module load order.

Regular files and processes require additional host-job and supervision layers.
They should not be implemented by treating regular descriptors as safely
non-blocking readiness resources.
