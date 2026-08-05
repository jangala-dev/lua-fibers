# Repository layout

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
performance/                validating local performance programmes
packages/                   exact-closure package catalogue and profiles
scripts/                    checks, builders and generated-target tooling
docs/                       guides, design and contributor material
```

The kernel is deliberately internal. Public code imports `fibers`, `fibers.op`, facilities, lifetimes or host adapters rather than evaluator modules.

## Main commands

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

## Package closure

`scripts/build-profile.lua` computes the static closure of selected public entries. Named profiles are conveniences; arbitrary repeated `--entry` arguments are supported. Dynamic native probing is confined to `fibers.io.auto`.

## Internal dependency direction

- `Operation` is immutable and does not depend on the scheduler;
- `Runtime` owns fibers, the ready queue and public execution phases;
- `Engine` owns pending operations, arbitration and commit authority;
- `Search` owns one speculative execution and its resumable state;
- `Journal` owns speculative managed state and rollback;
- `Proof` is a dynamic absence value; Engine owns its reverse invalidation graph;
- host adapters publish versioned facts rather than entering Search recursively;
- diagnostics observe through hooks and do not alter semantics.

`make check-modules` validates static imports and ambiguous module paths. `make check-packages` validates package boundaries and exact-closure profiles.
