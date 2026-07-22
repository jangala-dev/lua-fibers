# Repository layout

The repository is organised by audience and stability rather than by historical implementation terminology.

```text
src/fibers/             installed version 1 library
  init.lua              small application-facing concurrency language
  resource/             supported transactional resource toolkit
  external/             externally observed facts and runtime-bound feeds
  lifetime/             custody, borrowing, effects and task exits
  flow.lua and flow/    supported transactional byte facade and value types
  internal/flow_machine.lua transactional byte state machine
  internal/             closed kernel, shared waits, lifecycle and adoption machinery
  host/                 atomic host families, native adapters and runtime-owned reactor
  socket.lua and socket/ public socket facade, addresses, Listener, Dial and UDP
  process.lua and process/ owned Process facility and immutable Command builder
  file.lua and file/     evented pipes, regular files and provider implementations
  stream.lua            supported capability-shaped Stream facade

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

## Portable module shape

Shared Lua and Luau modules use an unambiguous filesystem convention.  Leaf
modules use `name.lua`.  A module that also contains child modules uses
`name/init.lua`.  A source tree must not contain both `name.lua` and `name/`,
or both `.lua` and `.luau` forms of the same module.

This is a filesystem rule only; logical names such as `fibers.scope` and
`fibers.scope.result` are unchanged.  The repository check
`scripts/check-module-layout.py` enforces it.
