# fibers

`fibers` is a small cooperative concurrency runtime for PUC Lua, LuaJIT and TeXLua implementing **eventful transactions**.

A fibre does not block by directly receiving, sleeping, locking or updating
shared state.  It performs an option value.  Option values can be stored,
passed around, chosen between, sequenced, combined, and then committed by the
runtime.

The practical model is:

```text
spawn fibres
fibres perform options
the runtime searches for a compatible committed world
resource changes and typed effects are committed
selected fibres resume with their results
```

The public atom kit is deliberately small:

```text
Op          first-class option over possible committed worlds
Scalar      transactional fact
Rendezvous  synchronous rendezvous
Index       ordered transactional stock
Counter     bounded numeric transactional stock
Keyed       per-key transactional map/set
Lease       compatibility-based transactional lease table
Source      external, host or time occurrence made transactional
Region      transactional ownership boundary
Effect      after-commit runtime obligation
```

`Task`, `Scope`, `Stream`, queues and scope policies are compound facilities
built from that kit, not additional atoms.  `Region.Owned` is the advanced
ownership constructor for resource authors and ownership facilities; ordinary
users should usually meet it through `Scope`, `Task` and `Stream`.

The algebra underneath is the distinctive part.  A commit is not just one event
synchronising with another event.  A commit selects a world containing
rendezvous requirements, resource journals, fallback structure, wake interests,
typed runtime effects, nacks, and post-commit value transformations.

The resource side is governed by a managed validity algebra.  Resources declare
managed facts such as scalars, queues, maps, leases and derived views.  Search
records the facts it relied on, and saved cursors or prepared worlds are reused
only while those fact stamps still validate.  This is what makes bounded search
and absence-sensitive fallback safe in the presence of external arrivals.

The names `fibers` and `op` acknowledge Andy Wingo's Snabb work, which adapted CML-style first-class synchronisation to Lua; here `Op` is read as option.

This repository is WIP.  The implementation is intended to be portable Lua.
The test suite is exercised with plain Lua, LuaJIT and texlua; optional host
backends skip cleanly when their dependencies are unavailable.

## Atom kit rule of thumb

```text
Single replacement facts and small state machines go in Scalars.
Ordered stock goes in Index.
Numeric stock goes in Counter.
Keyed facts go in Keyed.
Compatibility leases go in Lease.
Meetings go through Rendezvous values.
External occurrences arrive through Sources.
Ownership is recorded in Regions.
Running work is a Task, a compound built over Region, Scalar and Effect.
Practical scope management normally uses Scope, the lightweight lifetime container built over Region, Task, Source and Effect.
Committed obligations are Effects.
Everything composes as an Op, short for option.
```

## A first example

```lua
local fibers = require('fibers')

local ch = fibers.Rendezvous.new('inbox')
local message

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(ch:put_op('hello'))
  end, 'sender')

  message = fibers.perform(ch:get_op())
end)

print(message)
```

`fibers.run` creates the runtime and the root scope.  The friendly
`fibers.spawn` creates a structured `Task` owned by that current scope; raw
unstructured fibres remain available as `spawn_raw` for embedders and
low-level tests.

The send and receive are not two independent actions.  The runtime finds one
compatible transaction and resumes both fibres after the rendezvous has
committed.

## Choice with time

The sleep facility is ordinary option syntax built over a clock `Source`.
Relative sleep fixes its absolute deadline once for the perform attempt.

```lua
local op = fibers.choice(
  ch:get_op(),
  fibers.sleep_op(1.0):map(function()
    return nil, 'timeout'
  end)
)
```

The same `Source` idea is used for signals, queued host callbacks, clock
deadlines and readiness sources. Readiness is one source kind, not the whole
host model.

## Transactional state

Scalars participate in the same transaction machinery as rendezvous points.

```lua
local counter = fibers.Scalar.new(0, 'counter')

local increment = counter:read_op():and_then(function(old)
  return counter:write_op(old + 1):map(function() return old + 1 end)
end)
```

For replacement state, use `read_op` and `write_op`. For a small atomic
state machine, define typed transitions with `Scalar.transition` or
`Scalar.kind`, optionally add `validate(payload)`, then run them with
`transition_op`. Validation runs at operation construction. Transition callbacks receive
the projected scalar value and return the new value followed by operation result
values. Update and select transition premises are resolved in ordered
proof-contribution frames. Use `Effect`, not scalar transitions, for committed
external work. The raw `unsafe_update_op` and `unsafe_select_op` functions are
low-level building blocks for typed transitions, not the ordinary public idiom.

## Scopes, regions and tasks

A scope is the ordinary lightweight container for lifetimes.  Lifetime-bearing
facilities such as tasks and safe stream acquisition should be created inside a
scope so their custody can be settled, moved or reported.

```lua
local fibers = require('fibers')

fibers.scope(function(scope)
  local task = fibers.spawn(function()
    return 7
  end)

  local value = fibers.perform(task:await_op())
  assert(value == 7)
end)
```

The friendly `fibers.spawn` uses the current scope.  `Scope:spawn_op` is a
compound over task construction, scope admission and an after-commit spawn
effect.  If the admitting transaction loses, the task is not started.

The scope calculus is deliberately small:

```text
admit      take custody
move       transfer custody atomically
authorise  prove a right to use
borrow     grant temporary authority without custody
claim      take exclusive resolution authority
resolve    discharge, fail or restore a claim
seal       stop new custody
observe    explain the ledger
```

`Region` remains the ownership atom.  `Scope` is the compound facility most code
should use for spawning, ambient ownership, negotiated custody offers,
borrowing, observation, owned-item settlement and terminal reports.  Nursery,
supervisor and future phase APIs are policies over `Scope`, not special cases in
the algebra.

See `docs/scope.md`, `docs/scope_laws.md`, `docs/lifetime-calculus.md`,
`docs/authority-and-borrowing.md` and `docs/settlement.md`.

## Transactional streams

The top-level `fibers.Stream` is built from two unidirectional `fibers.Flow` values. `fibers.Flow` is the scalar-state-machine byte facility: an Inlet commits bytes into a Flow, an Outlet commits bytes out of a Flow, and ordinary bidirectional streams are compounds made from two Flows:

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

local line = fibers.perform(b:reader():read_line_op())
fibers.perform(a:writer():write_op('reply\n'))

local stream = fibers.perform(
  fibers.Stream.open_backend_in_op(region, backend, { name = 'host-stream' })
)

local r = stream:reader()
local w = stream:writer()
```

Inlet and Outlet `_op` methods are single-commit options.  Losing read branches
free no bytes; losing write branches append no bytes; `peek_op` observes without
freeing; reads are derived from peek plus prefix-freeing; `read_until_op` and
`read_including_op` provide delimiter-bounded reads; `splice_to` moves bytes between
flows as one committed world; EOF and endpoint closure are committed state; and
backpressure is retained-byte capacity.  Producer shutdown
drains, consumer shutdown discards retained bytes, transport failure fails retained
bytes, and flush waits for the fate of prior retained bytes.  If prior bytes have
already been consumed, flush succeeds even if the peer has since closed; later
writes still fail.  The reservoir is rope-backed and currently permits one active
lease at a time.  Stream compounds
use stable endpoint capabilities for byte movement; use `stream:reader()` and `stream:writer()`. These endpoints are the public stream authority surface.

See `docs/facilities/streams.md`, `docs/facilities/settlement.md`, `examples/09_memory_stream.lua`, `examples/11_pumped_stream_fake_backend.lua`, `examples/12_readiness_stream.lua`, `examples/13_socket_backend_contract.lua`, `examples/14_host_handle_stream.lua`, and `examples/15_owned_resource_settlement.lua`.

For resource authors, see `docs/kernel/resources.md`, `docs/kernel/resource-laws.md`,
`docs/kernel/validity-authoring.md`, and `docs/validity-algebra.md`.

## Effects

An effect is the public form of a typed transaction effect: runtime-owned
work that is discharged iff the selected world commits.

```lua
local op = fibers.after_commit(effect)
```

Effects are not participant continuations.  They are prepared and discharged by
the runtime after resource commit and before selected participants resume.

The current implementation provides in-process exactly-once discharge.  It is
not yet a crash-durable distributed outbox.

## Public modules

The tree is deliberately layered so that the repository does not turn into a
flat catalogue of modules:

```text
fibers                    convenience entry point
fibers.atoms               aggregate for the public atom kit
fibers.atoms.*             Op, Scalar, Rendezvous, Index, Counter, Keyed, Lease, Source, Region, Effect
fibers.task                owned running computation over Region/Scalar/Effect
fibers.sleep              clock-source sleep helpers
fibers.channel            small facade: capacity 0 Rendezvous, capacity >0 Queue
fibers.pulse              versioned broadcast Pulse over Scalar
fibers.waitgroup          WaitGroup over Scalar
fibers.mailbox            closeable Mailbox over Scalar + Queue/Rendezvous
fibers.scope              structured scope facility over Region/Task/Source/Effect
fibers.borrow             temporary authority as an owned obligation
fibers.phase              prototype rhythmic lifetime boundary with declared crossings over Scope
fibers.flow               Scalar-state-machine Flow
fibers.stream             bidirectional Stream over two Flows
fibers.policy             scope policies such as nursery
fibers.host               host adapter helpers
fibers.host.*             host helpers, HostHandle/fd support, and standalone/test host adapters
fibers.runner             standalone Runtime runner over a host
fibers.kernel             aggregate for advanced runtime/embedding use
fibers.kernel.*           runtime, transaction net, resources, waits and effects
fibers.internal.*         private implementation detail
```

The top-level module is the preferred starting point:

```lua
local fibers = require('fibers')

local scalar = fibers.Scalar.new(false)
local ch = fibers.Rendezvous.new()
local src = fibers.Source.signal('signal')
local scope = fibers.Scope.new('main')
local ch2 = fibers.Channel.new(2)
local pulse = fibers.Pulse.new()
local tx, rx = fibers.Mailbox.new(16)
local wg = fibers.WaitGroup.new()
local a, b = fibers.Stream.memory_pair()
local r = b:reader()
local w = a:writer()
```

## Protected calls

Use `fibers.pcall` or `fibers.xpcall` inside fibres when protected code may perform options. On Lua 5.1, native `pcall`/`xpcall` cannot reliably protect code that suspends and resumes, so `fibers` provides yieldable protected calls for fibre code without replacing the host globals.

This is deliberately proportionate: transaction search and commit internals remain non-suspending, and `perform` is only permitted from the currently resumed runtime fibre.

## Examples

The `examples/` directory contains small usage guides, not regression tests.
They are intended to be read and run individually:

```sh
texlua examples/01_rendezvous.lua
texlua examples/02_scalar.lua
# etc.
```

Assertion-heavy semantic checks live in `tests/`.

## Run the tests

From the repository root:

```sh
lua tests/run_all.lua
# or
luajit tests/run_all.lua
# or
texlua tests/run_all.lua
```

The test runner prints a uniform per-file result and summary.  It also supports
listing, filtering, verbose inner output and fail-fast mode:

```sh
lua tests/run_all.lua --list
lua tests/run_all.lua --filter source
lua tests/run_all.lua -k host
lua tests/run_all.lua --verbose
lua tests/run_all.lua --fail-fast
```

The same options are available through environment variables:

```sh
FIBERS_TEST_FILTER=host lua tests/run_all.lua
FIBERS_TEST_VERBOSE=1 lua tests/run_all.lua
```

Host tests can be run together or per backend.  Backend-specific tests skip
cleanly when their optional dependency is not available; in an environment with
nixio, luaposix, LuaJIT FFI and cffi available, the same commands exercise the real backends.

```text
pure          portable fallback; time waits only
nixio   nixio poll backend
luaposix      luaposix poll backend
luajit_linux  LuaJIT FFI epoll backend
cffi_linux    cffi epoll backend for plain Lua
```

The nixio, luaposix and FFI backend tests include smoke coverage for real pipe read
readiness, write readiness, readiness racing a timeout, and timeout racing an
unready descriptor:

```sh
lua tests/hosts/test_all.lua
lua tests/hosts/test_all.lua --filter nixio
lua tests/hosts/test_pure.lua
lua tests/hosts/test_nixio.lua
lua tests/hosts/test_luaposix.lua
lua tests/hosts/test_cffi_linux.lua
luajit tests/hosts/test_luajit_linux.lua
```

Run the benchmark suite with any supported Lua host:

```sh
lua benchmarks/bench.lua
luajit benchmarks/bench.lua
texlua benchmarks/bench.lua
```

The benchmark harness validates each case before reporting timings. It can be
scaled, filtered, or emitted as CSV/JSON:

```sh
FIBERS_BENCH_SCALE=5 lua benchmarks/bench.lua
FIBERS_BENCH_CASE=product lua benchmarks/bench.lua
FIBERS_BENCH_FORMAT=csv lua benchmarks/bench.lua
```

See `benchmarks/README.md` for the current case groups.

## Documentation

```text
docs/atoms.md                    the public atom kit
docs/structure.md                repository layers and placement rules
docs/algebra.md                  option algebra and semantic distinctions
docs/lifetime-calculus.md        custody, authority and obligations as the central design
docs/scope.md                    practical scope guide
docs/scope_laws.md               executable lifetime laws for Scope and Region
docs/authority-and-borrowing.md  custody versus authority, borrows and leases
docs/settlement.md               settlement as claim and resolution
docs/future-compounds.md         quarry notes: phase, membrane, escrow, tomb and related forms
docs/validity-algebra.md         managed validity facts and pull validation
docs/kernel/resources.md         open resource protocol
docs/kernel/resource-laws.md     open resource and effect laws
docs/kernel/validity-authoring.md managed validity resource-authoring guide
docs/effects.md                  typed transaction effects / effects
docs/facilities/sleep.md         sleep as a top-level facility over clock sources
docs/facilities/scopes.md        detailed scope and region API notes
docs/facilities/settlement.md    resource-author settlement details
docs/facilities/streams.md       byte flows, stream compounds and host-pumped streams
docs/facilities/host-handles.md  host I/O handles for pumped streams
docs/kernel/embedding.md         bounded stepping and host integration
```

## Strict managed validity branch

This experimental branch removes the fallback named-frontier path from the kernel resource boundary. Built-in resources now declare managed validity facts directly; resources without a managed validity fact fail at the protocol boundary instead of silently receiving an ad-hoc named frontier.

The remaining `frontier` terminology refers to generation-stamped managed facts used for pull validation. It no longer refers to the old push-invalidation watcher mechanism.

The scope lifetime laws are recorded in `docs/scope_laws.md`; the practical
scope API is described in `docs/scope.md`, with lower-level API notes in
`docs/facilities/scopes.md`.
