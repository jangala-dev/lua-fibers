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
4. writing a `.luaurc`;
5. generating the Luau conformance smoke programme and the named portable or
   reference test profile.

The initial build includes the kernel, runtime, Scope, Effect, Lifetime, Flow,
in-memory resources, host external protocols, the small ManualHost and PureHost. Shared
file and process
abstractions may enter the dependency closure, but native host bindings for
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
`make check-modules` checks the rule and resolves static Fibers imports.

## Current commands

```sh
make build-luau
make build-luau-reference
make check-luau
make test-luau-smoke
make test-luau-portable
make test-luau-reference
make test-luau
```

The portable build is written to `build/luau/`; the reference build is written
to `build/luau-reference/`. Separate trees avoid module-cache coupling and make
the selected default evaluator explicit in each generated runtime.

`check-luau` runs `luau-analyze` over the generated smoke, portable and
reference-profile entry points. `test-luau` runs all three with the standalone
Luau CLI. The narrower targets are available when diagnosing a failure.

Luau is part of `make test-matrix`. Native host integrations remain separate
because the standalone CLI does not provide the relevant capabilities.

## Experimental Roblox host

The generated Luau target now includes a deliberately narrow Roblox host
profile rather than a separate concurrency model:

```text
Roblox task scheduler / Actor VM
└── one Fibers runtime
    ├── proof and commit engine
    ├── lightweight internal fibres
    ├── Scopes, Lifetimes and Closure
    └── queued Roblox signal and shutdown adapters
```

The first slice consists of:

- `fibers.roblox.prepare`, which creates a root Runtime and Scope without taking
  control of the engine loop;
- `Application:advance`, which accepts a host time horizon and deterministic
  proof-work allowance, retaining unfinished work for a later turn;
- `fibers.roblox.attach`, which adds event-driven or RunService-phase scheduling
  above the manual boundary using `task.defer`, `task.delay` and `task.cancel`;
- `fibers.roblox.events`, `latest` and `pulse`, which give signal buffering an
  explicit application meaning;
- subscriptions held in custody, whose Lifetime Closure disconnects the corresponding
  `RBXScriptConnection`;
- `fibers.roblox.bind_to_close`, which publishes shutdown into the runtime and
  waits for root Closure or a declared deadline;
- fake scheduler, event, phase, signal and DataModel tests which run under stock
  Lua.

A normal Roblox callback only appends or coalesces an external delivery and
requests a future application turn. Proof search and participant continuation
resume later through `Application:advance`; they never run recursively inside the
engine callback. A selected RunService phase is itself a deliberate host-driver
boundary and remains subject to the application turn budget.

Host horizon exhaustion is scheduling suspension, not proof absence. It retains
the current runtime state and cannot admit an `or_else` fallback. Proof quantum
exhaustion remains the existing budget-pending/Unknown result and is likewise not
Retry.

The standalone Luau CLI cannot exercise Roblox Instances, so release validation
has two layers: generated-source and fake-engine conformance in the ordinary
matrix, then a real Studio smoke place before the adapter is promoted from
experimental. Wally/Rojo packaging is also still outstanding.

Player and character helpers, RemoteEvent protocols, data operations, asset
loading and Instance-specific custody remain application or future adapter work.
One Fibers world per Actor is the conservative initial boundary; transactions
should not span Actors until a distinct distributed protocol is designed.

The public learning path is described in [`../guide/roblox.md`](../guide/roblox.md).
Portable scenarios live under [`../../examples/gameplay/`](../../examples/gameplay/)
and Studio examples under [`../../examples/roblox/`](../../examples/roblox/).

## Promotion gates

### 1. Runtime conformance

The smoke programme must establish:

- portable module loading through `.luaurc` aliases;
- ManualHost deterministic scheduling and rendezvous;
- the application-facing `fibers.run` root-lifecycle path;
- table-valued error identity through `fibers.pcall`;
- no dependency on filesystem or process globals.

Add focused gates for coroutine identity, yieldable protected calls, weak
tables, packed nil-bearing returns and deep operation graphs as incompatibilities
are found.

### 2. Portable and reference test profiles

`tests/luau/profile.lua` classifies every `test_*.lua` file and defines the
`portable` profile. The profile contains 81 tests covering public
semantics, composition, resources, Effect/Lifetime/Scope semantics, ManualHost
embedding, test-only SimulatedHost I/O, both semantic evaluators, kernel laws, portable
implementation helpers, case
studies and performance architecture.

The `reference` profile inherits that list, selects the repository reference
evaluator as the generated runtime default and excludes five checks concerned
with ledger implementation structure or performance. It therefore reruns 76
portable semantic tests as an independent cross-check. Explicit `machine`
options in individual tests continue to override the profile default.

The builder generates each selected stock-Lua test as a Luau module.  It removes
the test-only `package.path` prelude, rewrites logical imports to aliases and
supplies a small `io.write` compatibility shim where required.  The generated
runner itself uses no `package`, `dofile`, `io` or environment variables.

The builder fails if a new `test_*.lua` file lacks a classification, if a
profile includes a non-portable test, or if a classified path has gone stale.
Tests therefore cannot disappear from the Luau run by accident.

### 3. Distribution shape

Once the portable suite passes, decide whether the supported artefact is:

- the generated alias-based source tree;
- a single bundled module with an internal module registry; or
- both, with the source tree used for analysis and the bundle used for
  distribution.

The generated source tree should remain deterministic and reproducible from the stock Lua sources.

### 4. Host integrations

The standalone Luau CLI can support ManualHost and an injected PureHost sleep
function.  Files, sockets and processes require a richer embedder or a separate
runtime such as Lute.  Those integrations should implement the existing host
capability contract and have their own provider-conformance jobs rather than
being implied by core Luau support.

### 5. Matrix inclusion

The development matrix includes Luau through `make test-luau`. Release and CI
jobs must therefore establish:

- the smoke, portable and reference profiles pass from a clean checkout;
- `luau-analyze` passes on both generated targets;
- the pinned Luau release or commit is recorded in CI output;
- unsupported native capabilities remain outside the portable matrix and are
  reported explicitly by any future host-specific jobs.
