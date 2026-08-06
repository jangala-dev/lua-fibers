# Contributing

This document covers the repository layout, ordinary development commands, package discipline and generated Luau artefacts. Compatibility and test matrices have their own operational references.

## Repository layout

```text
src/fibers/                 production library
  internal/kernel/          sole transactional evaluator
  resource/                 portable managed facilities
  lifetime/                 custody, grants and closure
  embed/                    bounded host driving
  io/, socket/, process/    host-neutral facilities and adapters
  roblox/                   Roblox integration

tests/                      semantic, kernel, host and stress tests
examples/                   tutorials, recipes and case studies
performance/                validating local performance programs
packages/                   exact-closure package catalogue and profiles
scripts/                    checks, builders and generated-target tooling
docs/                       guides, design and contributor material
```

The kernel is deliberately internal. Public code imports `fibers`, `fibers.op`, facilities, lifetimes or host adapters rather than evaluator modules.

### Main commands

```sh
make test
make test-kernel
make test-matrix
make test-native
make test-stress
make examples
make check
```

`make test` runs the ordinary semantic suite. `make test-matrix` repeats interpreter-sensitive semantics across available Lua versions, LuaJIT, TexLua and generated Luau. Native providers and sustained churn remain separate.

### Package closure

`scripts/build-profile.lua` computes the static closure of selected public entries. Named profiles are conveniences; arbitrary repeated `--entry` arguments are supported. Dynamic native probing is confined to `fibers.io.auto`.

### Internal dependency direction

- `Operation` is immutable and does not depend on the scheduler;
- `Runtime` owns fibers, the ready queue and public execution phases;
- `Engine` owns pending operations, arbitration and commit authority;
- `Search` owns one speculative execution and its resumable state;
- `Journal` owns speculative managed state and rollback;
- `Proof` is a dynamic absence value; Engine owns its reverse invalidation graph;
- host adapters publish versioned facts rather than entering Search recursively;
- diagnostics observe through hooks and do not alter semantics.

`make check-modules` validates static imports and ambiguous module paths. `make check-packages` validates package boundaries and exact-closure profiles.


## Luau build program

Luau uses a generated source tree because its module loader differs from stock Lua. The generated target retains the same execution-frontier kernel and public semantics.

### Commands

```sh
make build-luau
make check-luau
make test-luau-smoke
make test-luau-portable
make test-luau
```

The build is written to `build/luau/`. `scripts/build-luau.lua`:

- computes the required source closure;
- rewrites logical imports to `.luaurc` aliases;
- removes stock-Lua `package.path` test preludes;
- generates one module per selected test;
- emits smoke and portable test runners;
- rejects missing or stale test classifications.

`tests/luau/profile.lua` defines the portable test set and classifies every `test_*.lua` file. Host-specific native-provider tests remain outside the standalone Luau run.

### Roblox

The Roblox integration is a host adapter, not a second concurrency model. One Fibers runtime is driven through bounded application turns. Roblox callbacks queue or coalesce external deliveries and request a later turn; they do not enter transactional search recursively.

The stock-Lua fake-engine suite covers the portable driver, event adapters, shutdown handling and lifetime behaviour. A real Studio smoke place remains a separate release gate for Instances and engine scheduler behaviour.

### Distribution

The generated alias-based tree is the current analysis and test artefact. A future distribution may also provide a bundle, but it must be reproducible from the stock Lua sources and preserve the same module closure.


## Documentation discipline

Each public concept has one canonical home:

- application use belongs in `docs/guide/`;
- exact signatures belong in `docs/api-reference.md`;
- semantic and extension contracts belong in `docs/advanced/`;
- implementation machinery belongs in `docs/design/`;
- repository procedure belongs here or in the compatibility and testing references.

Other documents should summarise and link rather than create a second definition.

## Trusted changes

Changes to executable option leaves, absence claims, transition witnesses, effect discharge or callback phases require the review and regression obligations in [Extending Fibers](../advanced/extending.md).
