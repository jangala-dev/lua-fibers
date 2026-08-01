# Test profiles

Fibers separates semantic, interpreter, native-provider and stress coverage.

- `make test` runs the normal semantic suite and available native smoke tests.
- `make test-matrix` runs interpreter-sensitive semantics across supported Lua versions, LuaJIT, TexLua and generated Luau.
- `make test-native` runs provider and real-kernel integration where dependencies are available.
- `make test-stress` runs registration, connection and descriptor churn.
- `make test-full` combines the matrix, native, stress and examples.

`FIBERS_TEST_PROFILE` accepts `default`, `matrix` or `full` when running `tests/run_all.lua` directly.

## Kernel assurance

Kernel tests cover:

- `Hit`, `Retry` and `Unknown` separation;
- `choice`, `and_then`, `or_else`, `each` and `together` laws;
- exact and latent execution frontiers;
- selective invalidation;
- retained bounded search;
- rollback and speculative-store joins;
- candidate validation and defeat;
- guard activation identity;
- hard capacity limits.

Lifetime assurance is organised around custody, grants and closure rather than internal implementation mechanisms.

## Luau

```sh
make build-luau
make check-luau
make test-luau
```

Every test file has an explicit portability classification. The builder fails when a new test is unclassified or a classified path has gone stale.

## Repository checks

`make check` runs shell and Lua syntax, formatting, local links, module resolution, package boundaries and generated Luau build checks.
