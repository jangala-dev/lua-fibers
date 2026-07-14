# Repository layout

The repository is organised by audience and stability rather than by historical implementation terminology.

```text
src/fibers/             installed version 1 library
  init.lua              small application-facing concurrency language
  resource/             supported transactional resource toolkit
  external/             externally observed facts and runtime-bound feeds
  lifetime/             custody, borrowing, effects and task exits
  internal/             closed kernel, current Flow engine and other internals
  host/                 host adapters
  stream/               supported Stream implementation and backends

examples/tutorial/      ordinary application use
examples/recipes/       tested facilities built from supported modules
examples/embedding/     host and runtime integration
examples/lifetimes/     advanced custody and settlement examples
examples/case_studies/  trusted kernel programmes, not installed APIs

experiments/            prototypes with no compatibility promise
reference/              differential reference evaluator
performance/            benchmarks and architectural invariants
tests/                  tests grouped by public contract
```

## Public boundary

The root `fibers` module exports execution and option composition. Facilities, resource materials, lifetime types and embedding interfaces are imported from named modules.

Code under `fibers.internal` is not a supported application interface. Installed facilities must not depend on examples, experiments or tests.

## Test groups

`tests/groups.lua` defines the public, composition, resources, lifetimes, embedding, kernel, internal, case-study, experiment and performance groups. Run one group with:

```sh
lua tests/run_group.lua public
```

The default suite and the reference evaluator run remain:

```sh
lua tests/run_all.lua
FIBERS_MACHINE=reference lua tests/run_all.lua
```
