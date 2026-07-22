# Luau build programme

Luau is a separate build target rather than another stock-Lua executable.  Its
standalone CLI has string-based module loading but does not expose Lua's
`package`, `io`, `dofile`, `loadfile`, general environment access or native
extension loader.

The stock Lua source under `src/` remains canonical.  `make build-luau`
generates a target-specific tree under `build/luau/` by:

1. computing the static dependency closure of the portable public surface;
2. copying the canonical unambiguous module hierarchy as `.luau` files;
3. rewriting `fibers` to the alias root `@fibers` and submodules such as
   `fibers.runtime` to `@fibers/runtime`;
4. writing a `.luaurc` and deterministic manifest;
5. generating the first Luau smoke programme.

The initial build includes the kernel, runtime, scopes, lifetimes, flows,
in-memory resources, ManualHost and PureHost.  Shared file and process
abstractions may enter the dependency closure, but native host providers for
files, sockets and processes are deliberately outside the first target.

## Shared module layout

The canonical source tree uses one cross-runtime rule:

- a leaf module is `name.lua`;
- a module that also owns child modules is `name/init.lua`;
- `name.lua` and `name/` must never coexist.

For example, `fibers.scope` is stored at `src/fibers/scope/init.lua`, while
`fibers.scope.result` is stored at `src/fibers/scope/result.lua`.  Stock Lua
continues to load both through the normal `?.lua` and `?/init.lua` search
patterns, and Luau receives the same hierarchy without a target-specific move.
`make check-layout` enforces the rule.

## Current commands

```sh
make build-luau
make check-luau
make test-luau
```

`check-luau` runs `luau-analyze` over the generated smoke entry point.
`test-luau` then runs the entry point with the standalone Luau CLI.

Luau is not yet part of `make test-matrix`.  Promotion requires the gates below
to pass in the development container and CI.

## Promotion gates

### 1. Runtime conformance

The smoke programme must establish:

- portable module loading through `.luaurc` aliases;
- ManualHost scheduling and rendezvous;
- the application-facing `fibers.run` path;
- table-valued error identity through `fibers.pcall`;
- no dependency on filesystem or process globals.

Add focused gates for coroutine identity, yieldable protected calls, weak
tables, packed nil-bearing returns and deep operation graphs as incompatibilities
are found.

### 2. Portable test profile

Replace the single smoke programme with a generated Luau test manifest.  Start
with public semantics, composition, resources, lifetimes, kernel, internal
portable helpers and ManualHost embedding.  The runner must not depend on
`package.path`, `dofile`, `io` or environment variables.

A test must be marked explicitly as portable, host-specific or unavailable;
tests must not disappear from the Luau run by accident.

### 3. Distribution shape

Once the portable suite passes, decide whether the supported artefact is:

- the generated alias-based source tree;
- a single bundled module with an internal module registry; or
- both, with the source tree used for analysis and the bundle used for
  distribution.

The build manifest should remain deterministic and record every source module
and digest in either case.

### 4. Host integrations

The standalone Luau CLI can support ManualHost and an injected PureHost sleep
function.  Files, sockets and processes require a richer embedder or a separate
runtime such as Lute.  Those integrations should implement the existing host
capability contract and have their own provider-conformance jobs rather than
being implied by core Luau support.

### 5. Matrix inclusion

Add Luau to the release matrix only when:

- `make test-luau` passes from a clean checkout;
- the portable profile has named coverage comparable to stock Lua's matrix
  profile;
- `luau-analyze` passes on the generated target;
- the pinned Luau release or commit is recorded in CI output;
- unsupported native capabilities are reported explicitly.
