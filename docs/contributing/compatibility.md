# Lua compatibility

The production source uses the Lua 5.1 grammar. The version 1 support policy is
limited to:

```text
Lua 5.1
Lua 5.2
Lua 5.3
Lua 5.4
Lua 5.5
LuaJIT v2.1
TexLua (Lua 5.3-derived)
Luau
```

LuaJIT support follows the maintained `v2.1` production branch. Release and CI
environments should record the exact tested commit. Luau is a distinct runtime
target: it does not share the stock-Lua module-loading and native-extension
environment, so its loader and host adapter are verified separately.

Compatibility paths cover standard-library and coroutine differences:

```text
unpack                 table.unpack or the Lua 5.1 global unpack
yieldable protection   coroutine-backed fibers.pcall and fibers.xpcall
coroutine identity     normalised in fibers.internal.protected
bit operations         confined to optional native host backends
```

Code which may suspend must use `fibers.pcall`, `fibers.xpcall`, or the internal
protected-call helper. Native Lua 5.1 `pcall` and `xpcall` cannot yield across
their C boundary.

## Development matrix

The development container builds all supported interpreters. The stock-Lua and
LuaJIT commands are versioned explicitly:

```text
lua5.1  lua5.2  lua5.3  lua5.4  lua5.5
luajit  texlua  luau  luau-analyze
```

LuaRocks wrappers install native modules into separate ABI-specific prefixes:

```text
luarocks-5.1 ... luarocks-5.5
luarocks-luajit
```

`cffi-lua` is installed for stock Lua 5.1–5.5. Native host adapters resolve
native bit operations first (LuaJIT's built-in `bit` library or Lua 5.3+
native operators), then a `bit` module, then global or installed `bit32`.
The `bit32` compatibility rock remains installed for Lua 5.1 and Lua 5.4.
`luaposix` is installed for Lua 5.1–5.4 and LuaJIT; its current
release does not declare Lua 5.5 support. The LuaJIT FFI backend uses LuaJIT's
built-in `ffi`. `nixio` is installed in the development container for Lua
5.1 and LuaJIT, the Lua 5.1 ABI family targeted by its upstream build defaults.

## Verification

From the repository root:

```sh
make test-matrix
make test-texlua
make test-reference
make test-luau
lua5.1 tests/run_protected_fallback.lua
luajit -joff tests/run_all.lua
```

These checks should be combined with environment-specific native-host tests.
The reference solver is repository-only and is deliberately outside `src/`.

## Native I/O capabilities

Host support is capability-based rather than implied by interpreter support.
The Linux FFI host family provides epoll readiness, numeric descriptors,
pipes, IPv4/IPv6/Unix stream sockets, IPv4/IPv6 datagrams and process-honest
fork/exec. The luaposix host provides the same stream-socket and process
contracts over `poll`, plus a blocking `getaddrinfo` resolver.

The Nixio host provides stream sockets, a blocking resolver and evented child
processes through a per-command reaper and status pipe. It supports piped and
null standard streams, environment replacement, working directories, new
sessions, group-directed shutdown and exactly-once child reaping. Nixio does
not expose close-on-exec or arbitrary process-group assignment, so the host
reports the narrower guarantees explicitly:

```text
process_exec_proof = false
process_pass_fds = false
process_close_fds = "known"
process_groups = "session"
```

Executable and working-directory failures are preflighted, and child setup
failures are reported before the process becomes visible. A final exec race
cannot be proved without close-on-exec support. Only Fibers-created descriptors
are closed in the child; arbitrary inherited descriptors and numeric process
groups remain unsupported.

Hosts with synchronous `getaddrinfo` advertise `resolver_blocking = true`.
The public socket resolver prefers Fibers' own DNS-over-UDP/TCP implementation
when such a host also provides stream and datagram sockets. This keeps network
resolution off the runtime thread while preserving the host resolver as a
compatibility fallback when no DNS configuration can be found. Applications
which cannot permit that fallback set `require_nonblocking = true` or supply an
explicit `socket.dns_resolver`.

The deterministic ManualHost supplies virtual pipes, sockets, datagrams and
resolver records for semantic tests. Its native resolver is non-blocking and is
therefore retained by default; DNS wire tests select the Fibers resolver
explicitly. Optional hosts advertise only capabilities whose provider contracts
pass and return structured unsupported errors for the remainder.

## Evented file capabilities

`capabilities.file` means the public regular-file surface can run without
issuing filesystem calls on the runtime thread. `file_backend` identifies the
selected complete mechanism:

```text
io_uring   Linux FFI ring operations
worker     persistent and one-shot helper processes over evented pipes
memory     deterministic ManualHost storage
```

Linux FFI hosts probe `io_uring` at construction. `file_io_uring` reports a
usable ring and `file_aio_detected` reports the presence of the POSIX AIO symbol set; it does not report selection of an AIO backend.
AIO availability is informational at present: it cannot by itself provide
evented open, final close and path mutation, so a host without `io_uring` uses
the complete worker backend rather than performing those calls synchronously.
Luaposix and Nixio use the worker backend when their process capability is
available. PureHost reports files as unsupported.

Native socket conformance tests include loopback TCP, Unix sockets, repeated
connection churn, readiness retirement and descriptor reuse paths. Datagram
conformance adds IPv4 and IPv6 loopback, source-address and message-boundary
preservation, zero-length messages, truncation and repeated open/close churn.
The Linux FFI host reports exact truncation metadata. The luaposix and Nixio
adapters implement the same datagram contract when installed, but currently
advertise `datagram_truncation = false` because their exposed receive calls do
not provide the original wire length. They run only when the corresponding
provider is installed; a skipped optional host is not evidence that its native
path has passed.

## Authoring rules

Portable production code should:

```text
avoid syntax introduced after Lua 5.1
use table.unpack or unpack through a local compatibility binding
avoid relying on native yieldable pcall in Lua 5.1
avoid undefined length behaviour for sparse arrays
preserve nil-bearing multiple values through explicit packed tuples
keep bitwise syntax and FFI declarations inside optional backend modules
```

Option and result code must preserve the exact number of return values. The
kernel uses packed tables with an explicit `n` field for this reason.


See [Test profiles](testing.md) for the semantic, native and stress split.

See [Luau build programme](luau.md) for the generated portable and reference
targets included in the development matrix.
