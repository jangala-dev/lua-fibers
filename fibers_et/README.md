# fibers

`fibers` is a cooperative concurrency runtime for PUC Lua, LuaJIT and TeXLua. It implements **eventful transactions**: fibres perform first-class operation values, and the runtime searches for a compatible committed world containing communication, resource changes and runtime obligations.

The core operation grammar is:

```text
always(value)
primitive(resource, request)
choose(Op...)
and_then(Op, value -> Op)
product(independent | interacting, Op...)
or_else(Op, Op)
consequence(commit_obligation)
```

`never`, `map`, `guard`, `all`, `tensor` and `emit` are derived forms.

The central distinctions are:

```text
choose        unordered competing alternatives with committed rotation
or_else       fallback after proof-carrying Retry
all           independent lanes in one commit
tensor        interacting lanes which may satisfy one another
consequence   runtime work entailed by commit
wrap          a participant's post-commit value transformation
Retry         no world under recorded facts; wait for change
Unknown       bounded search has not established an answer
```

The runtime is portable and embeddable. Native readiness backends are optional.

## First programme

```lua
local fibers = require('fibers')

local inbox = fibers.Rendezvous.new('inbox')

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(inbox:put_op('hello'))
  end, 'sender')

  local message = fibers.perform(inbox:get_op())
  assert(message == 'hello')
end)
```

`fibers.run` creates a runtime and root scope. `fibers.spawn` creates a structured task owned by the current scope. `fibers.perform` submits an operation to the runtime.

The send and receive commit as one rendezvous. Neither side proceeds alone.

## Choice and time

```lua
local value, err = fibers.perform(fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1.0):map(function()
    return nil, 'timeout'
  end)
))
```

Time, readiness and external events are ordinary resources. External mutation is authorised through runtime-bound feed capabilities rather than a privileged source mechanism.

`choice` source order does not express priority. Continuously eligible branches
of a repeatedly committed choice are served by deterministic rotation. Use
`or_else` for proof-dependent preference, and `fibers.choice_key(name)` with
`:with_choice_key(key)` when a choice is reconstructed but should retain its
rotation. `fibers.run` and `Runtime.new` accept
`choice = { mode = 'rotating', seed = ... }` for reproducible arbitration.

## Transactional state

```lua
local counter = fibers.Scalar.new(0, 'counter')

local increment = counter:read_op():and_then(function(old)
  return counter:write_op(old + 1):map(function()
    return old + 1
  end)
end)

assert(fibers.perform(increment) == 1)
```

`Scalar` is suitable for replacement facts and small state machines. The standard resource kit also includes:

```text
Rendezvous  synchronous meetings
Index       ordered stock
Counter     bounded numeric stock
Keyed       keyed facts
Lease       compatibility-managed rights
Signal      externally latched fact
EventQueue  externally fed occurrence queue
Clock       host-time observation
Readiness   host readiness level
Region      ownership and custody ledger
Effect      typed commit and defeat obligations
```

Compound facilities such as `Task`, `Scope`, `Queue`, `Mailbox`, `Flow` and `Stream` are built from those resources.

## Structured lifetimes

```lua
fibers.scope(function()
  local task = fibers.spawn(function()
    return 7
  end)

  assert(fibers.perform(task:await_op()) == 7)
end)
```

A scope owns its tasks and other admitted obligations. On exit it seals, settles remaining custody according to policy, and reports unresolved failure rather than discarding it. Custody movement and borrowing are explicit operations.

## Streams

Streams are bidirectional compounds over two transactional byte flows:

```lua
local a, b = fibers.Stream.memory_pair({ capacity = 4096 })

fibers.perform(a:writer():write_op('hello\n'))
assert(fibers.perform(b:reader():read_line_op()) == 'hello')
```

Reads, writes, delimiter scans, leases and splices are operations. Losing alternatives do not consume or append bytes. Host-backed streams use readiness resources and pump tasks; the practical API is covered in the guide and the host contract in the embedding document.

## Running the repository

Run the tests with any supported Lua implementation:

```sh
lua tests/run_all.lua
luajit tests/run_all.lua
texlua tests/run_all.lua
```

Useful test options include:

```sh
lua tests/run_all.lua --list
lua tests/run_all.lua --filter external
lua tests/run_all.lua --verbose
lua tests/run_all.lua --fail-fast
```

Run examples individually:

```sh
texlua examples/01_rendezvous.lua
texlua examples/04_scope_task.lua
texlua examples/09_memory_stream.lua
```

Run the validating benchmark suite with:

```sh
lua benchmarks/bench.lua
FIBERS_BENCH_SCALE=5 lua benchmarks/bench.lua
FIBERS_BENCH_CASE=product lua benchmarks/bench.lua
```

See `examples/README.md` and `benchmarks/README.md` for the local indexes.

## Documentation

The maintained documentation set is deliberately small:

```text
docs/guide.md               ordinary programming and facility use
docs/algebra.md             semantic model, laws and non-laws
docs/comparison.md          comparison with CSP, CML, TE and Reagents
docs/lifetimes.md           scopes, custody, authority and settlement
docs/resource-authoring.md  open resource protocol and validity rules
docs/embedding.md           bounded stepping, feeds, hosts and readiness
docs/internals.md           repository structure and implementation pipeline
```

Design material which is not part of the supported model is kept under `docs/notes/`.

This repository is work in progress. The current runtime provides in-process transactional guarantees; it is not a crash-durable transaction manager.
