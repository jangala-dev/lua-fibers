# Repository layout

The source tree is organised by semantic ownership. A public concept has one
canonical import path; the root `fibers` module is a lifecycle and contextual
prelude rather than a catalogue of the package tree.

```text
src/fibers/
  init.lua                 root lifecycle plus current-fibre operations:
                           run, spawn, perform, now and nested scopes
  op.lua                   inert option algebra
  runtime.lua              embedded runtime, host driving and serial commit
  scope/                   structured lifetime boundary and policy
  task.lua                 public Task value

  channel.lua              common application communication
  mailbox.lua              split messaging endpoints
  pulse.lua                coalescing notification
  sleep.lua                direct and composable time waits
  stream.lua               public readable, writable and duplex interfaces

  resource/                lower-level transactional building blocks
    flow/                  transactional transfer atom, leases and rope storage
    queue.lua              transactional queue
    scalar.lua             scalar state and typed transitions
    completion.lua         one-shot completion resource
    rendezvous.lua         synchronous exchange
    counter.lua            counted stock
    index.lua              indexed transactional collection
    keyed.lua              keyed allocation
    lease.lua              transactional leasing
    authoring.lua          trusted facility compilation materials

  effect.lua               committed obligation kinds and effects
  region/
    init.lua               custody, ownership handles and claims
    settlement.lua         custody settlement protocol
    adoption.lua           host-acquisition adoption protocol
  diagnostics/             optional I/O audit and proof-search observation

  file/                    evented files, pipes and provider implementations
  process/                 Command and owned Process facility
  socket/                  addresses, Listener, Dial, UDP and shared protocols
  host/                    host contracts, reactor and native bindings

  internal/
    protected.lua          cross-version yieldable protected calls
    kernel/                closed production proof and transaction kernel

examples/tutorial/         ordinary application use
examples/recipes/          tested facilities built from supported modules
examples/embedding/        host and runtime integration
examples/lifetimes/        advanced custody and settlement examples
examples/case_studies/     trusted kernel programmes, not installed APIs

docs/notes/                design notes and work-in-progress prototypes
reference/                 independent differential evaluator
performance/               benchmarks and architectural invariants
tests/                     core tests grouped by semantic contract
```

## Public imports

The root module contains the root lifecycle and operations interpreted by the
currently running fibre:

```lua
local fibers = require('fibers')

fibers.run(fn, opts)
fibers.try_run(fn, opts)
fibers.perform(op)
fibers.spawn(fn, name)
fibers.now()
fibers.pcall(fn, ...)
fibers.scope(fn)
fibers.try_scope(fn)
```

Types, constructors and option combinators use their one canonical module:

```lua
local Op = require('fibers.op')
local Channel = require('fibers.channel')
local Stream = require('fibers.stream')
local Flow = require('fibers.resource.flow')
local Queue = require('fibers.resource.queue')
```

There is no `fibers.resource` façade and no duplicate top-level façade for
Flow, Queue or Scalar. Top-level placement denotes common application
vocabulary; `resource/` denotes lower-level transactional construction.

## Ownership rule

A source file should answer one of these questions clearly:

- Which public concept does it define?
- Which subsystem owns this shared protocol?
- Which correctness boundary of the kernel does it protect?

A small implementation used by one owner is merged into that owner. A separate
private module is retained only when it is substantial, shared within the
subsystem or independently testable as a correctness boundary. Global
`fibers.internal` is reserved for the closed kernel and the cross-version
protected-call implementation.

## Flow and Stream

`fibers.resource.flow` is the transactional transfer atom. It can be composed
to build buffering, tees, encoders and other transfer structures.
`fibers.stream` assembles one or more Flows into a persistent public interface.
Files, processes and sockets provide Streams, and users may also construct
memory-backed Streams directly.

The dependency direction is one-way:

```text
Op → resource primitives → Flow → Stream → File / Process / Socket
```

## Test groups

`tests/groups.lua` defines convenient public, composition, resources, lifetimes,
embedding, kernel, internal, case-study and performance runs. Tests for recipes,
documented examples and case studies live beside those examples and are included
by the same groups. These
lists organise targeted commands; semantic tests do not inspect repository
layout. Run one group with:

```sh
lua tests/run_group.lua public
```

The default suite and the reference evaluator run remain:

```sh
lua tests/run_all.lua
FIBERS_MACHINE=reference lua tests/run_all.lua
```

## Portable module shape

Shared Lua and Luau modules use an unambiguous filesystem convention. Leaf
modules use `name.lua`. A module that also contains child modules uses
`name/init.lua`. A source tree must not contain both `name.lua` and `name/`, or
both `.lua` and `.luau` forms of the same module.

This is a filesystem rule only; logical names such as `fibers.scope` and
`fibers.scope.result` are unchanged. `scripts/check-modules.lua` checks duplicate logical modules, ambiguous module
paths and unresolved static Fibers imports. Package ownership remains a design
and review concern rather than a frozen test invariant.
