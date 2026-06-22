# Host handles

A `HostHandle` is the named boundary between host I/O and pumped byte streams.
It is deliberately smaller than sockets, subprocesses or files.

```text
host readiness
  says trying I/O may be productive

HostHandle read/write
  performs the authoritative non-blocking I/O attempt

Stream pump
  moves bytes between HostHandle and transactional Flows
```

The contract is:

```lua
handle:readiness_key()
handle:read_ready_op()
handle:write_ready_op()
handle:read(max)              -- bytes | nil, err
handle:write(bytes)           -- n | nil, err
handle:shutdown_read(reason)
handle:shutdown_write(reason)
handle:close(reason)
```

Readiness is only a hint.  A handle may still return `would_block` after its
readiness option commits.  In that case the readiness hint should be cleared
or consumed before the pump waits again.

## Manual/fake handles

`fibers.host.Handle.fake` is a deterministic handle for tests and examples:

```lua
local host = fibers.host.manual({ auto_advance_time = false })
local handle = fibers.host.Handle.fake({ host = host, key = 'demo' })
local stream = fibers.perform(fibers.Stream.open_handle_op(region, handle))
```

The fake handle has helpers such as:

```lua
handle:feed_read(bytes)
handle:feed_eof()
handle:block_writes()
handle:unblock_writes()
handle:written()
```

It uses the same readiness path as real host handles, so it is useful for
exercising stream pumps without OS support.

## Host families and fd handles

Select a complete host family once and use its paired fd implementation:

```lua
local host = fibers.host.luaposix()
local r, w = host.fd.pipe({ host = host })
```

The public family constructors are:

```text
fibers.host.luajit_linux()  LuaJIT FFI epoll + numeric fd handles
fibers.host.cffi_linux()    cffi epoll + numeric fd handles
fibers.host.luaposix()      luaposix poll + numeric fd handles
fibers.host.nixio()         nixio poll + nixio handle objects
fibers.host.manual()        deterministic test/embedding host
fibers.host.pure()          time-only pure Lua host
```

`fibers.host.fd` is now a low-level registry/selector for tests and advanced
code.  Ordinary code should use `host.fd` from the selected host family.

The fd implementations currently cover wrapping descriptors/objects,
non-blocking read/write, close/shutdown, and `pipe()` for smoke tests.
Sockets, subprocesses and files should build on this handle contract rather
than inventing separate stream backends.

## Mode-split handles

A real pipe is not a duplex socket: its read and write ends have different
readiness keys.  `Handle.duplex(read_handle, write_handle)` composes two
directional handles into the duplex shape expected by `Stream.open_handle_op`:

```lua
local Handle = require('fibers.host.handle')
local r, w = Fd.pipe({ host = host })
local h = Handle.duplex(r, w, { name = 'pipe-duplex' })
local stream = fibers.perform(fibers.Stream.open_handle_op(region, h))
```

This is mainly a test and plumbing helper.  Subprocess support will usually
expose separate stdin/stdout/stderr streams rather than presenting the whole
process as one duplex pipe.
