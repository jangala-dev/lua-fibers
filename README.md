# Fibers

Readable structured concurrency for Lua and Luau.

Fibers lets a programme describe possible concurrent actions, combine those descriptions in ordinary Lua, and perform one coherent result. The same small vocabulary applies to channels, time, transactional state, task lifetimes and host resources.

Fibers version 1 is an advanced work in progress. Its public surface is being reduced and settled before the first release.

## Begin with sequential fibre code

Fibres run ordinary Lua functions. Everyday facilities provide direct methods for the common case, so each fibre can be read from top to bottom:

```lua
local fibers = require('fibers')
local channel = require('fibers.channel')

local jobs = channel.new()
local replies = channel.new()

fibers.run(function()
  fibers.spawn(function()
    local job = jobs:get()
    replies:put('completed ' .. job)
  end, 'worker')

  jobs:put('inspection')
  print(replies:get())
end)
```

`spawn` starts the worker in the current scope. The direct `get` and `put` methods perform their actions in place, suspending only when another participant is required.

## Compose the same actions when needed

Each direct method has an inert `_op` form. Asking for the `Op` lets the same actions be combined before one coherent result is performed:

```lua
local jobs = channel.new()
local replies = channel.new()
local stop = channel.new()

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(jobs:get_op():and_then(function(job)
      return replies:put_op('completed ' .. job)
    end))
  end, 'worker')

  local completed = jobs:put_op('inspection')
    :and_then(function()
      return replies:get_op()
    end)
    :map(function(reply)
      return 'worker: ' .. reply
    end)

  local stopped = stop:get_op():map(function(reason)
    return 'stopped: ' .. reason
  end)

  local outcome = fibers.perform(fibers.choice(completed, stopped))
  print(outcome)
end)
```

This can be read directly:

> Either send the inspection job and then receive its reply, or receive a reason to stop.

Both sides describe the complete exchange, so the sends, receives and sequencing remain provisional until `perform` selects one coherent outcome. The same vocabulary extends to time, state, task lifetimes and host resources.

The complete runnable example is [`examples/tutorial/00_getting_started.lua`](examples/tutorial/00_getting_started.lua).

## The model

Five ideas are enough to begin.

### Fibres are ordinary sequential code

A fibre is a cooperatively scheduled Lua function. Within a fibre, code remains direct and sequential.

```lua
fibers.spawn(function()
  local message = fibers.perform(inbox:get_op())
  handle(message)
end)
```

### Options describe possible actions

An option is inert. Constructing one does not send, receive, sleep or change state.

An `Op` can be thought of as an option: an inert description which may be combined before it is submitted to `perform`. Methods ending in `_op` return these descriptions.

```lua
local receive = inbox:get_op()
local timeout = fibers.sleep_op(1)
```

The suffix keeps possible actions visible in application code.

### `perform` resolves an option

`perform` submits an option to the runtime and is the explicit execution and suspension boundary.

```lua
local message = fibers.perform(inbox:get_op())
```

The option may commit immediately, wait for other participants, or compose several actions into one transaction. Application code uses the same boundary in each case.

### Direct methods are the gentle on-ramp

Selected everyday facilities also provide a direct performing method:

```lua
local message = inbox:get()
```

This is exactly:

```lua
local message = fibers.perform(inbox:get_op())
```

Use the direct form for ordinary sequential fibre code. Ask for an option when
the action needs to join `choice`, `or_else`, sequencing or a product. The
facility method and the explicit form share one implementation and return the
same values and errors.

```lua
local message = fibers.perform(fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1):map(function()
    return 'timeout'
  end)
))
```

### Effects belong to committed worlds

An effect is a typed runtime obligation selected with an option and discharged only if that world commits. Fibers uses effects for task spawning, interruption, scope notification and host wake-up.

Most application code uses effects through ordinary facilities rather than constructing them directly. The important guarantee is that speculative alternatives do not start tasks or mutate the outside world merely because they were considered.

### Scopes account for lifetimes

Every structured task belongs to a scope. A scope accounts for its children and retained obligations before it returns.

```lua
fibers.run(function(scope)
  local task = scope:spawn(function()
    return produce_result()
  end, 'worker')

  return fibers.perform(task:await_op())
end)
```

Options compose possibilities. Scopes compose lifetimes.

## A small algebra

In Fibers, an algebra is simply a small set of ways to combine options. No formal background is required. The useful property is that the same combinations retain their meanings across different facilities.

| Expression | Read it as |
|---|---|
| `always(value)` | this result is already available |
| `never()` | this construction cannot succeed |
| `choice(a, b)` | either coherent result is acceptable |
| `a:or_else(b)` | use `b` only with certified present absence of `a` |
| `a:and_then(f)` | continue transactionally from the result of `a` |
| `all({ a, b })` | satisfy both without positive supply between siblings |
| `tensor({ a, b })` | satisfy both, allowing compatible sibling hand-off |
| `a:map(f)` | transform a speculative result |
| `a:wrap(f)` | run participant-local code after commitment |

Most programmes begin with `perform`, `choice`, `or_else`, `and_then`, `wrap`, `spawn` and scopes. The product operators become useful when several requirements must form one decision.

### Choice expresses permission

```lua
local result = fibers.perform(fibers.choice(
  inbox:get_op(),
  fibers.sleep_op(1):wrap(function()
    return 'timeout'
  end)
))
```

Either result is acceptable. If several branches can commit, source order does not make the first one a priority.

### `or_else` requires proof

```lua
local result = preferred:or_else(fallback)
```

The fallback is not chosen because `preferred` appears locally blocked or because a search budget has been exhausted. It becomes eligible only after the relevant preferred search has been refuted under recorded managed facts.

This distinction is central:

```text
choice(a, b)  either result is permitted
a:or_else(b)  b requires a valid refutation of a
```

The preferred side may itself contain choices, products, state transitions and chains of communication. If any coherent committed world satisfies it, Fibers still prefers it.

Internally, Fibers distinguishes:

- a constructive result;
- an exhaustive present refutation;
- an undecided bounded search.

An undecided search is not treated as absence. Implementation limits therefore do not silently change the meaning of `or_else`.

### Sequencing remains transactional

```lua
local reserve_and_send = slots:take_op(1):and_then(function()
  return requests:put_op('start')
end)
```

The slot is not consumed independently if the continuation cannot complete. Earlier communication and state changes remain provisional until the whole sequence commits.

Callbacks used by `map`, `and_then` and transactional resource transitions may be revisited during proof search. They must be deterministic, non-yielding and free of irreversible side effects.

### Two forms of conjunction

`all` combines requirements which must each be supportable without positive supply from their siblings:

```lua
fibers.all({
  account_a:take_op(1),
  account_b:take_op(1),
})
```

One lane cannot fund the other.

`tensor` permits compatible siblings to participate in an intentional transactional hand-off:

```lua
fibers.tensor({
  slots:give_op(1),
  slots:take_op(1),
})
```

Both forms still commit as one coherent world. The distinction is whether sibling options may positively make one another possible.

## Committed work

Concurrent programmes need a clear account of when callbacks run.

### During proof search

`map`, `and_then`, guards and resource-transition callbacks calculate possible worlds. They may be replayed and must not perform irreversible work.

### After a participant commits

`wrap` runs in the resumed fibre after its option has committed:

```lua
local receive_and_report = inbox:get_op():wrap(function(message)
  print('received:', message)
  return message
end)
```

A wrap may perform further options because proof search has finished for the selected occurrence.

### As part of the committed world

Typed effects represent obligations which belong to the selected world itself. They are prepared transactionally and discharged only after commitment. Task admission is an important example: a task whose admission option loses is never started.

Advanced facilities can define effect kinds, but most users encounter effects through tasks, scopes, interruption and host-backed resources. See [`docs/advanced/option-algebra.md`](docs/advanced/option-algebra.md) for the complete distinction, including defeat obligations.

## Structured lifetimes

`fibers.run` creates a runtime and root scope. `fibers.spawn` starts a task in the current scope; `fibers.scope` creates a nested boundary.

```lua
local fibers = require('fibers')

fibers.run(function()
  local task = fibers.spawn(function()
    return 40 + 2
  end, 'worker')

  assert(fibers.perform(task:await_op()) == 42)
end)
```

The raising forms `run` and `scope` return body values or raise after their boundaries have accounted for retained custody. `try_run` and `try_scope` return structured results instead.

The lifetime model also supports cancellation, owned resources, transactional movement, borrowing, claims and settlement. These facilities are deliberately progressive: ordinary programmes can begin with tasks and scopes, while systems code can state stronger ownership protocols where required.

See [`docs/advanced/lifetimes-and-custody.md`](docs/advanced/lifetimes-and-custody.md).

## Everyday facilities

The root `fibers` module contains the execution and composition language. Facilities live in named modules.

### Channels

```lua
local channel = require('fibers.channel')

local synchronous = channel.new()
local buffered = channel.new(16)
```

Both forms expose `put_op` and `get_op` and compose with the same algebra.

### Transactional state

```lua
local Scalar = require('fibers.scalar')
local state = Scalar.new('idle', 'state')

fibers.perform(state:expect_op('idle'):and_then(function()
  return state:write_op('running')
end))
```

Scalar also supports typed state-machine transitions for facilities whose rules should be defined once and reused.

### Notification, messaging and byte flow

`fibers.pulse` provides coalescing change notification. `fibers.mailbox` provides split sender and receiver endpoints, closure and selectable overflow policies.

`fibers.flow` is the transactional byte-building block: it provides backpressure, exact and incrementally scanned delimiter reads, closure, data leases and producer-side capacity leases. `fibers.stream` builds readable, writable or duplex facilities from one or two Flows. Committed Flow changes notify host service through a deduplicated post-commit effect. All host-backed directions in one Runtime share one indexed poller and one lazily created reactor rather than allocating one task per direction.

### Pipes

Anonymous pipes are owned pairs of one-way Streams:

```lua
local file = require('fibers.file')
local reader, writer, err = fibers.perform(file.pipe_op())
assert(reader, err)

fibers.perform(writer:write_op('hello'))
fibers.perform(writer:close_op())
local bytes = fibers.perform(reader:read_all_op({ max = 4096 }))
```

Pipe acquisition occurs only after `pipe_op` commits. Newly created host handles
are covered immediately by temporary adoption records until their permanent
Stream ownership has been admitted. See [`docs/guide/io.md`](docs/guide/io.md).

### Processes

Commands are immutable descriptions; starting one creates an owned Process with
ordinary Fibers Streams for configured standard input and output:

```lua
local process = require('fibers.process')

local proc = assert(process.command({
  'sh', '-c', 'printf hello',
  stdin = 'null',
  stdout = 'pipe',
  stderr = 'pipe',
}):start())

local result = assert(proc:communicate({
  stdout_limit = 1024,
  stderr_limit = 1024,
}))

assert(result.stdout == 'hello')
assert(process.succeeded(result.status))
proc:close('complete')
```

Launch admission, launch completion and process exit are separate phases.
`launch_op()` uses a guard to construct a fresh Process at synchronisation time;
its committed supervisor effect performs the irreversible host launch.
`start()` is the direct launch-plus-handshake convenience. `result_op()` can then
participate in choice and becomes ready only after the child has been reaped.
Scope settlement closes stdin, requests graceful termination, escalates where
required, and retains signal, reap or close failure. See
[`docs/guide/io.md`](docs/guide/io.md).

### Sockets and name resolution

Listeners accept duplex Streams, while an outbound `Dial` separates starting a
connection attempt from observing or composing its eventual result:

```lua
local socket = require('fibers.socket')

local listener = assert(socket.listen_ipv4('127.0.0.1', 8080))
local dial = socket.dial_ipv4('127.0.0.1', 8080)
local connection, err = dial:result()
```

IPv4, IPv6 and Unix addresses are explicit values. Host names are unresolved
endpoints and pass through an owned resolver query:

```lua
local query = socket.resolve_name('example.org', 443)
local addresses, resolve_err = query:result()
assert(addresses, resolve_err)

local dial = socket.dial(addresses[1])
```

Accepted and connected Streams remain owned by their Listener or Dial until a
claim moves the complete Stream subtree into the caller's scope. Native Linux
FFI hosts provide non-blocking IPv4, IPv6 and Unix stream sockets. Verified
LuaJIT/cffi hosts may also expose a blocking `getaddrinfo` resolver and declare
that limitation; compatibility FFI providers do not advertise it. See
[`docs/guide/io.md`](docs/guide/io.md).

### Datagrams

UDP sockets preserve message boundaries and source addresses rather than
pretending to be byte Streams:

```lua
local socket = require('fibers.socket')

local udp = assert(socket.udp_ipv4('0.0.0.0', 0))
udp:send_to('hello', socket.ipv4_address('192.0.2.10', 9000))
udp:flush()

local packet, receive_err = udp:receive_from({ max_size = 4096 })
```

`send_to_op` admits one indivisible message to a bounded outbound queue.
`flush_op` observes completion of messages admitted before it was constructed;
it does not imply remote delivery. Incoming queues are bounded, and received
records retain the peer address, truncation status and original size where the
host can report it. Native Linux FFI hosts support IPv4 and IPv6 UDP; luaposix
and Nixio providers use the same host contract when those modules are present.
See [`docs/guide/io.md`](docs/guide/io.md).

### Time

```lua
fibers.perform(fibers.sleep_op(0.25))
```

Timers are options, so timeouts require no separate cancellation mechanism.

Lower-level materials for facility authors live under `fibers.resource`, `fibers.external` and `fibers.lifetime`. Worked facilities are kept in [`examples/recipes/`](examples/recipes/) rather than expanding the principal API.

## Why the algebra goes further

Fibers is designed for readable application code, but its small surface carries stronger semantics than ordinary event selection.

- **Transactional continuation:** `and_then` can join several communications and state changes into one all-or-nothing protocol.
- **Certified priority:** `or_else` distinguishes a genuine proof of present absence from incomplete search.
- **Two conjunctions:** `all` and `tensor` distinguish joint requirements from intentional transactional hand-off.
- **Occurrence-sensitive commitment:** wraps, effects and defeat obligations belong to precise dynamic option occurrences.
- **Cross-resource decisions:** communication, state, external observations, ownership changes and selected consequences can participate in one coherent commit.

The implementation searches for a compatible resource world, validates the facts on which that world depends, and commits it through one serial authority. A separate repository-local reference evaluator runs the same semantic test corpus using a simpler strategy.

Readers interested in CSP, Concurrent ML, Transactional Events, Reagents or transactional memory may wish to begin with:

- [`docs/design/comparison.md`](docs/design/comparison.md)
- [`docs/advanced/option-algebra.md`](docs/advanced/option-algebra.md)
- [`docs/design/kernel.md`](docs/design/kernel.md)
- [`reference/README.md`](reference/README.md)

The project does not presently claim a denotational semantics, a mechanised proof, a published encoding result, fairness for unordered choice, or lock-free parallel commit. The comparison document states the present strengths and limits directly.

## Intended uses

Fibers is intended for programmes whose concurrent behaviour should remain readable as it becomes more exact. This includes interactive systems written in Lua or Luau, as well as device, robotics and control software where suspension, cancellation, resource lifetime and failure boundaries need to remain visible.

The same expression can therefore be read at two levels:

- as a plain description of what the programme should do;
- as a precise statement about which actions may commit together.

Fibers coordinates work within one cooperative runtime domain. It is not a durable database, a distributed transaction system or a substitute for hardware fault containment.

## Project status and compatibility

Version 1 is an advanced work in progress. The core algebra, runtime, resource substrate, lifetime model and reference evaluator are substantial, but the public API and packaging are still being settled.

The production source uses the Lua 5.1 grammar. The development matrix covers:

```text
Lua 5.1, 5.2, 5.3, 5.4 and 5.5
LuaJIT v2.1
Luau
```

Luau has a distinct loader and host-integration path. Native host facilities also depend on the selected environment. See [`docs/contributing/compatibility.md`](docs/contributing/compatibility.md) for the current policy and verification commands.

## Getting started

From a repository checkout:

```sh
make test
make examples
```

Run the opening example directly with an available Lua interpreter:

```sh
lua5.4 examples/tutorial/00_getting_started.lua
```

Until the first packaged release, add `src` to the Lua module path or vendor `src/fibers` with the application. The programming guide begins with the public surface and ordinary facilities:

- [`docs/guide/getting-started.md`](docs/guide/getting-started.md)
- [`examples/README.md`](examples/README.md)

## Further reading

### Using Fibers

- [Programming guide](docs/guide/getting-started.md)
- [Direct methods and options](docs/guide/direct-and-options.md)
- [Pipes and sockets](docs/guide/io.md)
- [Tutorial and embedding examples](examples/README.md)
- [Facility recipes](examples/recipes/README.md)

### Understanding the design

- [Option algebra](docs/advanced/option-algebra.md)
- [Lifetimes, custody and settlement](docs/advanced/lifetimes-and-custody.md)
- [Flows, streams and the host reactor](docs/advanced/flows-and-streams.md)
- [Embedding and host integration](docs/advanced/embedding.md)
- [Comparison with related systems](docs/design/comparison.md)
- [Kernel design](docs/design/kernel.md)

### Extending and contributing

- [Facility authoring](docs/advanced/facility-authoring.md)
- [Trusted resource programmes](docs/contributing/trusted-resource-programmes.md)
- [Repository layout](docs/contributing/repository-layout.md)
- [Lua compatibility](docs/contributing/compatibility.md)
- [Test profiles](docs/contributing/testing.md)
