# fibers

`fibers` is a small cooperative concurrency runtime for Lua, built on
**eventful transactions**.

A fibre does not block by directly receiving, sleeping, locking or updating
shared state.  It performs an operation value.  Operation values can be stored,
passed around, chosen between, sequenced, combined, and then committed by the
runtime.

The practical model is:

```text
spawn fibres
fibres perform operations
the runtime searches for a compatible committed world
resource changes and typed effects are committed
selected fibres resume with their results
```

The public base kit is deliberately small:

```text
Op       possible transaction
Cell     transactional fact
Channel  synchronous rendezvous
Source   external, host or time occurrence made transactional
Region   transactional ownership boundary
Task     owned running computation
Effect   after-commit runtime obligation
```

`Lifetime` and launch policies are compound facilities built from that kit, not
additional base nouns.  `Region.Owned` is the advanced ownership constructor for
resource authors and ownership facilities; ordinary users should usually meet it
through `Lifetime`, `Task` and `Stream`.

The algebra underneath is the distinctive part.  A commit is not just one event
synchronising with another event.  A commit selects a world containing
rendezvous requirements, resource journals, fallback structure, wake interests,
typed runtime effects, nacks, and post-commit value transformations.

This repository is WIP.  The implementation is intended to be portable Lua.
The test suite is exercised with plain Lua, LuaJIT and texlua; optional host
backends skip cleanly when their dependencies are unavailable.

## Base kit rule of thumb

```text
Facts go in Cells.
Meetings go through Channels.
External occurrences arrive through Sources.
Ownership is recorded in Regions.
Practical lifetime management normally uses Lifetime, a compound facility built over Region, Task, Source and Effect.
Running work is a Task.
Committed obligations are Effects.
Everything composes as an Op.
```

## A first example

```lua
local fibers = require('fibers')

local ch = fibers.Channel.new('inbox')
local message

fibers.launch(fibers.facility.policy.nursery(), function()
  fibers.spawn(function()
    fibers.perform(ch:put_op('hello'))
  end, 'sender')

  message = fibers.perform(ch:get_op())
end)

print(message)
```

`fibers.launch` installs an explicit lifetime policy.  Inside the nursery
policy, the friendly `fibers.spawn` creates a structured `Task`; raw unstructured
fibres remain available as `spawn_raw` for embedders and low-level tests.

The send and receive are not two independent actions.  The runtime finds one
compatible transaction and resumes both fibres after the rendezvous has
committed.

## Choice with time

The sleep facility is ordinary operation syntax built over a clock `Source`.
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

Cells participate in the same transaction machinery as channels.

```lua
local counter = fibers.Cell.new(0, 'counter')

local increment = counter:read_op():and_then(function(old)
  return counter:write_op(old + 1):map(function() return old + 1 end)
end)
```

Cell operations do not run user update callbacks.  Interpret cell values with
ordinary `Op` composition such as `and_then`, and use `Effect` for committed
external work.

## Lifetimes, regions and tasks

A region is a generic ownership and admission boundary.  A task is the standard owned computation: it is admitted to a region and started after the admitting transaction commits.

```lua
local life = fibers.Lifetime.new('main')
local a, b = fibers.Stream.memory_pair()

fibers.run(function()
  local task = fibers.perform(life:spawn_op(function()
    return 7
  end, { name = 'child' }))

  local value = fibers.perform(task:await_op())
  assert(value == 7)
  fibers.perform(life:settle_item_op(task))
end)
```

`Region` is the ownership primitive: admit, reassign, seal and release. `Lifetime` is the compound facility most code should use for spawning, cancellation, matched handoff, observation, owned-item settlement and terminal settlement. Nursery and supervisor-style APIs are policies over `Lifetime`, not special cases in the algebra.

## Transactional streams

The stream facility is built from unidirectional Flows.  An Inlet commits bytes into a Flow, an Outlet commits bytes out of a Flow, and ordinary bidirectional streams are compounds made from two Flows:

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

local line = fibers.perform(b:reader():read_line_op())
fibers.perform(a:writer():write_op('reply\n'))

local stream = fibers.perform(
  fibers.Stream.open_backend_op(region, backend, { name = 'host-stream' })
)

local r = stream:reader()
local w = stream:writer()
```

Inlet and Outlet `_op` methods are single-commit operations.  Losing read branches
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
do not expose byte operations directly; use `stream:reader()` and `stream:writer()`.

See `docs/facilities/streams.md`, `docs/facilities/settlement.md`, `examples/09_memory_stream.lua`, `examples/11_pumped_stream_fake_backend.lua`, `examples/12_readiness_stream.lua`, `examples/13_socket_backend_contract.lua`, `examples/14_host_handle_stream.lua`, and `examples/15_owned_resource_settlement.lua`.

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
fibers.base               aggregate for the public base kit
fibers.base.*             Op, Cell, Channel, Source, Region, Task, Effect
fibers.facility           aggregate for compound facilities
fibers.facility.*         Sleep, Lifetime, Stream/Flow and policy facilities
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

local cell = fibers.Cell.new(false)
local ch = fibers.Channel.new()
local src = fibers.Source.signal('signal')
local life = fibers.Lifetime.new('main')
local a, b = fibers.Stream.memory_pair()
local r = b:reader()
local w = a:writer()
```

## Protected calls

Use `fibers.pcall` or `fibers.xpcall` inside fibres when protected code may perform operations. On Lua 5.1, native `pcall`/`xpcall` cannot reliably protect code that suspends and resumes, so `fibers` provides yieldable protected calls for fibre code without replacing the host globals.

This is deliberately proportionate: transaction search and commit internals remain non-suspending, and `perform` is only permitted from the currently resumed runtime fibre.

## Examples

The `examples/` directory contains small usage guides, not regression tests.
They are intended to be read and run individually:

```sh
texlua examples/01_channel.lua
texlua examples/02_cell.lua
texlua examples/03_source.lua
texlua examples/04_lifetime_task.lua
texlua examples/05_effect.lua
texlua examples/06_policy_nursery.lua
texlua examples/07_lifetime_handoff.lua
texlua examples/08_sleep.lua
texlua examples/09_memory_stream.lua
texlua examples/10_stream_protocol_handoff.lua
texlua examples/11_pumped_stream_fake_backend.lua
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
docs/base-kit.md       the public base kit
docs/structure.md      repository layers and placement rules
docs/algebra.md        operation algebra and semantic distinctions
docs/kernel/resources.md      open resource protocol
docs/kernel/resource-laws.md  open resource and effect laws
docs/effects.md   typed transaction effects / effects
docs/facilities/sleep.md      sleep as a facility over clock sources
docs/facilities/lifetimes.md  regions, tasks and ownership
docs/facilities/settlement.md claims, settlement protocols and failure state
docs/facilities/streams.md    byte flows, stream compounds and host-pumped streams
docs/facilities/host-handles.md host I/O handles for pumped streams
docs/kernel/embedding.md      bounded stepping and host integration
```
