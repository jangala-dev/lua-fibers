# Fibers v1 package restructuring

This change establishes package and embedding boundaries without changing the
operation algebra or normal application surface.

## Resulting package families

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
fibers-full
```

Published packages are deliberately coarser than deployment components. An
application may select any module roots accepted by `scripts/build-profile.lua`;
the builder emits the exact static closure and a package/size report.

`fibers-core` owns the operation language, evaluator, Runtime, Lifetimes,
portable resources, memory Streams and the generic embedding boundary. It does
not probe native implementations.

`fibers-io` owns host-neutral handle, readiness, reactor, host-backed Stream,
socket, file, DNS and process facilities. Backend packages provide complete
implementation families. `fibers.io.Platform` may nevertheless compose their
clock, wait, socket, file, process and resolver capabilities independently when
their readiness domains are compatible.

`fibers-roblox` is an engine integration. Luau remains a generated language and
distribution target rather than an I/O backend.

## Canonical namespaces

```text
fibers.embed.*       generic embedded driving and external delivery
fibers.io.*          host-neutral I/O and native backend implementations
fibers.net.*         neutral network values
fibers.roblox.*      Roblox scheduling and subscriptions
```

Automatic native I/O backend probing is confined to `fibers.io.auto`;
portable and engine hosts are selected from `fibers.embed.*` and
`fibers.roblox`. Public code uses the canonical namespaces directly.

## Embedding

The bounded, non-blocking application driver has moved from the Roblox adapter
to `fibers.embed.Application`. `fibers.embed.Queue` provides the common
re-entry-safe callback queue. Roblox now adds only task/RunService scheduling,
engine subscriptions and its completion bridge.

The same boundary can be used by a game engine, GUI loop, browser bridge,
custom Luau VM or other embedder:

```lua
local Embed = require('fibers.embed')

local host = Embed.Queue.new({ now = monotonic_now })
local app = Embed.Application.new(main, { host = host, owns_host = false })
local status = app:advance({
  horizon = monotonic_now() + 0.002,
  max_steps = 128,
  max_work = 512,
})
```

## Portable and host-backed Streams

`fibers.stream` now contains only Flow-backed Stream values, memory pairs and
portable composition. It has no static dependency on the host reactor.
`fibers.io.stream` adds transactional opening over a host handle. The former
`fibers.stream.open_op` compatibility delegate has been removed; host-backed
streams use `fibers.io.stream.open_op`.

An exact build rooted at `fibers.stream` contains no `fibers.io.stream` or
`fibers.io.reactor` module.

## Diagnostics

Runtime semantics no longer depend on the full I/O audit implementation. Core
contains an installable no-op observation hook; `fibers-diagnostics` supplies
the search and I/O observers. Runtime instrumentation is loaded only when
requested.

## Build and package tooling

- `packages/catalogue.lua` defines published ownership and package dependencies.
- `packages/profiles.lua` contains named example selections.
- `packages/dynamic_requires.lua` records deliberate runtime-selected imports.
- `scripts/check-packages.lua` rejects static dependencies crossing an
  undeclared package boundary.
- `scripts/build-profile.lua` emits a reduced module tree or one
  `package.preload` bundle from named profiles or arbitrary repeated `--entry`
  roots.
- `scripts/build-packages.lua` emits the coarse published source trees and
  manifests.

Examples:

```sh
# A named complete nixio profile
texlua scripts/build-profile.lua \
  --profile io-nixio \
  --output build/nixio \
  --report build/nixio/REPORT.txt

# An arbitrary core-only selection
texlua scripts/build-profile.lua \
  --entry fibers \
  --entry fibers.channel \
  --entry fibers.stream \
  --bundle build/application.lua \
  --report build/application.txt

# A specialist combination
texlua scripts/build-profile.lua \
  --entry fibers \
  --entry fibers.socket \
  --entry fibers.io.luajit_linux \
  --entry application.file_provider \
  --output build/application
```

The final example assumes the application provider is in the builder's source
module set; applications may extend the same closure resolver or vendor the
resulting selected tree.

## Post-restructure cleanup

The subsequent cleanup pass tightened the new boundaries without changing the
operation or lifetime semantics:

- `fibers.perform` now depends on a small dynamic-context module rather than the
  complete Runtime implementation; this removes the former Runtime/resource
  dependency cycle.
- Structured I/O errors are canonical in `fibers.io.error`, and the private host
  acquisition hold is owned by `fibers-io` rather than `fibers-core`.
- `fibers.io.auto` discovers native I/O backends only. Portable hosts are selected
  from `fibers.embed.*`, and Roblox remains under `fibers.roblox`.
- Manually advanced Roblox applications no longer require the Roblox task library
  or a `BindableEvent`; those capabilities are acquired only by attached or
  blocking convenience paths.
- Package ownership is explicit and longest-prefix deterministic. A newly added
  module must be assigned deliberately rather than silently entering core.
- Portable Streams no longer expose the removed host-backed `open_op` delegate.
- The build scripts share one ownership implementation, generated bundles support
  Lua 5.1-style `loadstring`, and the direct syntax checker examines the complete
  repository by default.
- Twenty-nine stale `require` bindings were removed after a source-wide audit.

## Verification performed

- Production ledger matrix: 112 passed, 0 failed.
- Reference evaluator default suite: 114 passed, 10 unavailable native backends
  skipped, 0 failed, in one interpreter process.
- Native group: 1 portable host test passed and 10 unavailable native backends
  skipped.
- Module-boundary check: 148 modules classified.
- Published-package check: 11 package definitions accepted.
- Lua syntax check: 383 source, reference, test, example, package and script files
  accepted.
- Markdown link check: 42 files and 93 local links accepted.
- Luau generation: 113 portable modules with 85 portable tests, and 113 modules
  with 80 reference tests.
- Forty-five runnable examples completed successfully.
- Generated package trees and a core-only Stream bundle passed smoke tests.

The earlier same-process reference performance cliff did not recur in the current
124-test default run. No causal claim is made; retained reference-evaluator
performance should continue to be watched as the suite grows.

## Deliberate remaining work

This is the first structural tranche. The following can proceed without another
public namespace migration:

1. Split the large POSIX implementation internally where a deployment needs
   function-level minimisation within one complete backend.
2. Move remaining Runtime convenience constructors behind installed services if
   a smaller evaluator-only embedding profile becomes necessary.
3. Add Roblox/Wally and private embedded-registry emitters alongside the current
   standalone Luau generator.
4. Add package manifests for external application providers and lockstep release
   metadata once the v1 semantic surface is frozen.
5. Continue profiling the reference evaluator in aggregate runs as the conformance
   suite grows.
