# Test profiles

Fibers separates three different questions which should not be multiplied
indiscriminately across every Lua interpreter.

- `make test` runs the normal semantic suite plus native smoke tests available
  to the selected interpreter. It excludes sustained churn.
- `make test-matrix` runs interpreter-sensitive semantics across supported Lua
  versions, LuaJIT, TexLua and the generated Luau target. It excludes native
  provider integration and stress loops.
- `make test-native` runs provider and real-kernel integration under Lua 5.4
  and LuaJIT.
- `make test-stress` runs registration, connection and descriptor churn.
- `make test-full` combines the matrix, native, stress, reference and examples
  for release qualification.

The environment variable `FIBERS_TEST_PROFILE` accepts `default`, `matrix`, or
`full` when invoking `tests/run_all.lua` directly. Stress loop sizes may be
raised with `FIBERS_STRESS_SOCKET_CYCLES` and
`FIBERS_STRESS_DATAGRAM_CYCLES`.

Lifetime assurance is organised around the three public laws rather than former
implementation mechanisms:

- custody tests cover unique parentage, atomic movement and ordered children;
- Grant tests cover rights, direction, revocation, transfer terms and subject
  liveness;
- Closure tests cover propagation, parent-first requests, child-first finishing,
  retained failure progress and single-use recovery authority.

Internal close tokens and host holds have focused implementation tests, but are
not part of the public Lifetime contract.

## TexLua and Luau

`make test-texlua` runs the stock matrix profile under the Lua 5.3-derived
TexLua interpreter.  It is part of `make test-matrix`.

Luau uses a generated portable target because its module loader and host
environment differ from stock Lua:

```sh
make build-luau
make build-luau-reference
make check-luau
make test-luau-smoke
make test-luau-portable
make test-luau-reference
make test-luau
```

`make test-roblox-fake` runs the Roblox adapter against the deterministic
fake engine.

`tests/embedding/test_roblox.lua` is a portable fake-engine conformance test,
not a Studio example. It intentionally runs in the stock-Lua matrix as well
as the generated Luau profiles, because the adapter shares the portable
driver, protected-call and lifetime machinery. Real Roblox Instances and
scheduler behaviour remain a separate Studio smoke gate.

The portable profile is declared in `tests/luau/profile.lua`; every test file
has an explicit portability classification. The reference profile inherits
the portable profile and reruns its semantic surface with the repository
reference evaluator, excluding implementation-specific ledger and performance
checks. `make test-luau` and `make test-matrix` run both profiles. See
[Luau build programme](luau.md).
## Repository checks

`make check` runs the repository-wide static checks:

- shell and Lua script syntax;
- StyLua formatting;
- local Markdown links;
- unambiguous modules and resolvable static Fibers imports;
- portable and reference Luau generation, including full test classification.

The build-only `make check-luau-build` target validates both generated Luau
trees without requiring `luau` or `luau-analyze`. `make check-luau` and
`make test-luau` add analysis and execution when those tools are installed.
