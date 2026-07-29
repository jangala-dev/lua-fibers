# Packages, profiles and embedding

Fibers v1 separates the semantic system, host-neutral I/O contracts, operating-system implementations and engine integrations. Package installation is deliberately coarser than deployment selection.

## Published package families

```text
fibers-core
fibers-io
fibers-io-linux
fibers-io-ffi
fibers-io-cffi
fibers-io-luaposix
fibers-io-nixio
fibers-roblox
fibers-diagnostics
fibers-reference
```

`fibers-core` contains the operation language, evaluator, Runtime, structured Lifetimes, portable resources and the generic embedding boundary. It does not probe native packages.

`fibers-io` contains host-neutral I/O contracts and facilities: errors, handles, readiness, the reactor, host-backed Streams, sockets, files, DNS and processes. Portable Flow-backed Streams and memory pairs remain in `fibers-core`. It does not select an implementation.

`fibers-io-linux` contains the shared Linux binding implementation used by the LuaJIT FFI and CFFI loaders. It does not choose a binding library itself.

Each `fibers-io-<backend>` package supplies a coherent operating-system implementation. A backend package may provide polling, time, sockets, files, pipes and processes together, while deployment tooling may retain only the modules reached by the application.

`fibers-roblox` is an engine integration rather than an I/O backend. Luau itself is a language and distribution target, not a statement about available files, sockets or processes.

## Canonical namespaces

```text
fibers.embed.*       generic external delivery and bounded driving
fibers.io.*          host-neutral I/O contracts and native backends
fibers.net.*         neutral network value types
fibers.roblox.*      Roblox scheduling and engine adapters
```

Automatic native I/O backend probing is isolated in:

```lua
local Auto = require('fibers.io.auto')
local host = Auto.default()
```

Portable hosts, engine integrations and constrained I/O programmes should select explicitly:

```lua
local Nixio = require('fibers.io.nixio')
local result = fibers.run(main, { host = Nixio.new() })
```

## Composable platforms

Backend packages provide coherent complete hosts, but the common I/O layer does
not require an application to use one backend for every capability.
`fibers.io.Platform` assembles independent providers and validates the readiness
domain used by handle-producing facilities:

```lua
local IO = require('fibers.io')
local FFI = require('fibers.io.luajit_linux').new()
local Posix = require('fibers.io.luaposix').new()

local platform = IO.Platform.new({
  driver = FFI,
  sockets = FFI,
  files = Posix,
  processes = Posix,
  resolver = application_resolver,
})
```

The example is accepted only when the selected wait driver can observe the
handles produced by the file and process providers. Backends declare a
`wait_domain`; differing domains require an explicit compatibility policy.
Resolver-only providers are not constrained because they do not place handles
in the readiness set.

A complete backend remains the ordinary case:

```lua
local backend = require('fibers.io.nixio').new()
local platform = IO.Platform.from(backend)
```

Package selection and capability composition are separate. Installing
`fibers-io-nixio` makes the complete nixio family available; an exact-closure
build still includes only the modules reached from the selected entries.

## Generic embedding

`fibers.embed.Application` owns a Runtime and root Scope and advances them without blocking the surrounding host:

```lua
local Embed = require('fibers.embed')

local host = Embed.Queue.new({
  now = monotonic_now,
})

local app = Embed.Application.new(main, {
  host = host,
  owns_host = false,
})

local status = app:advance({
  horizon = monotonic_now() + turn_budget,
  max_steps = 128,
  max_work = 512,
})
```

Host callbacks enqueue deliveries through `Embed.Queue`; they do not enter the evaluator recursively. The surrounding event loop decides when to call `advance` again from `needs_immediate_resume`, `next_deadline` and external interests.

Roblox builds on this boundary. `fibers.roblox.app` adds `task.defer`, `task.delay` and RunService phase scheduling; `fibers.roblox.host` adds the BindableEvent completion bridge. The semantic driver is no longer Roblox-specific.

## Exact-closure deployments

Published packages make features available. A deployment profile selects the precise module roots used by one programme.

```sh
lua scripts/build-profile.lua \
  --entry fibers \
  --entry fibers.channel \
  --entry fibers.io.nixio \
  --output build/application \
  --report build/application/REPORT.txt
```

Named example profiles are also provided:

```sh
lua scripts/build-profile.lua --profile core-minimal --output build/core
lua scripts/build-profile.lua --profile roblox --output build/roblox
lua scripts/build-profile.lua --profile io-nixio --output build/nixio
```

The builder follows literal module dependencies, emits only the reachable source tree and reports the contribution of each published package. It can instead produce one `package.preload` bundle with `--bundle`.

Runtime-selected dependencies are listed in `packages/dynamic_requires.lua`. They are not silently added to a constrained build. In particular, diagnostics and automatic backend discovery remain optional.

## Dependency direction

The intended direction is:

```text
operation language and kernel
        ↓
Runtime, Lifetimes and portable resources
        ↓
generic embedding boundary
        ↓
host-neutral I/O facilities
        ↓
native I/O backends or engine adapters
```

A low-level backend must not depend on a high-level socket façade. Network address values therefore live under `fibers.net.address`, below both socket facilities and native providers.

## Luau artefacts

Luau distributions are generated forms of `fibers-core` and selected integrations, not a separate semantic package. Likely release artefacts include:

```text
Lua module tree
standalone Luau alias tree
Roblox/Wally ModuleScript tree
single embedded module registry
```

One Fibers Runtime remains a serial transactional world. Separate Luau Actors or other independently scheduled VM instances communicate through external messages; transactions and custody transfers do not span those runtimes implicitly.
