# Fibers

Transactional concurrency and accountable lifetimes for Lua and Luau.

Fibers is designed for firmware controllers, robotics, emergency and field
systems, highly concurrent desktop and server applications, and embedded C,
C++ and Rust hosts. The same model also supports ambitious game logic, with
Luau and Roblox as first-class proving grounds.

A programme describes possible concurrent actions, combines those descriptions
in ordinary Lua, and performs one coherent result. The same small vocabulary
applies to channels, time, transactional state, task lifetimes, custody and
host resources.

Fibers version 1 is an advanced work in progress. Its public surface is being reduced and settled before the first release.

## Begin with sequential fibre code

Fibres run ordinary Lua functions. Everyday facilities provide direct methods for the common case, so each fibre can be read from top to bottom:

```lua
local fibers = require('fibers')
local channel = require('fibers.channel')

local commands = channel.new()
local results = channel.new()

fibers.run(function()
  fibers.spawn(function()
    local command = commands:get()
    results:put('completed ' .. command)
  end, 'command-worker')

  commands:put('refresh configuration')
  print(results:get())
end)
```

`fibers.spawn` starts the worker in the current scope. The direct `get` and `put` methods perform their actions in place, suspending only when another participant is required.

## Compose the same actions when needed

Each direct method has an inert `_op` form. Asking for the option form lets the same actions be combined before one coherent result is performed:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local channel = require('fibers.channel')

local commands = channel.new()
local acknowledgements = channel.new()
local stop_requests = channel.new()

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(commands:get_op():and_then(function(command)
      return acknowledgements:put_op('completed ' .. command)
    end))
  end, 'command-worker')

  local do_work = commands:put_op('refresh state')
    :and_then(function()
      return acknowledgements:get_op()
    end)
    :map(function(reply)
      return 'work: ' .. reply
    end)

  local stop = stop_requests:get_op():map(function(reason)
    return 'stopped: ' .. reason
  end)

  print(fibers.perform(Op.choice(do_work, stop)))
end)
```

This can be read directly:

> Either refresh the state and receive its acknowledgement, or receive a reason to stop.

Both sides describe the complete exchange, so the sends, receives and sequencing remain provisional until `perform` selects one coherent outcome.

The runnable progression begins with two deliberately generic examples: [`examples/tutorial/00_getting_started.lua`](examples/tutorial/00_getting_started.lua) and [`01_direct_methods_and_options.lua`](examples/tutorial/01_direct_methods_and_options.lua). It then ranges through emergency coordination, robotics, field communications, desktop workloads, firmware, games, servers, host embedding and custody. The [example index](examples/README.md) gives the complete route.

## Built for ambitious behaviour

Fibers is not tied to one application domain. The same small language can describe:

| Domain | Example decision |
|---|---|
| Firmware and controllers | read a sensor, meet one boot deadline and leave actuators in a safe state |
| Robotics and autonomy | reserve motion and perception capacity, then admit one coherent trajectory |
| Emergency and field systems | confirm a hazard, reserve communications and dispatch a connected response unit |
| Highly concurrent desktop and server applications | admit work, supervise background services and retain failed shutdown as an outstanding obligation |
| Games, Luau and Roblox | complete or skip a cutscene, close player work under custody and compose ambitious mechanics cleanly |
| Embedded plugin hosts | expose bounded C, C++ or Rust resources while guest logic remains within explicit custody and Closure |

The portable tutorial moves among these domains so that the concurrency vocabulary, rather than one scenario, remains the organising idea. The dedicated [`examples/gameplay/`](examples/gameplay/) collection develops cutscenes, player sessions, matchmaking, AI intention, camera custody and game mechanics in greater depth.

The experimental [`fibers.roblox`](src/fibers/roblox/init.lua) adapter embeds the runtime through a bounded `prepare`/`advance` boundary, with event- and RunService-phase scheduling, signal subscriptions under Lifetime custody and root shutdown handling above it. [`examples/roblox/`](examples/roblox/) and [`docs/guide/roblox.md`](docs/guide/roblox.md) provide the Studio examples and step-by-step path. These sit alongside the firmware, robotics, field and hosted-system uses from which the design grew.

## The model

Two semantic ideas organise the system; five practical ideas are enough to begin.

### Fibres are ordinary sequential code

A fibre is a cooperatively scheduled Lua function. Within a fibre, code remains direct and sequential.

```lua
fibers.spawn(function()
  local command = fibers.perform(commands:get_op())
  apply_command(command)
end, 'command-worker')
```

### Options describe possible actions

An option is inert. Constructing one does not send, receive, sleep or change state.

In this documentation, an option is the concept; `Op` is the Lua type representing an option. An option is an inert description which may be combined before it is submitted to `perform`. Methods ending in `_op` return these descriptions.

```lua
local await_shutdown = stop_requests:get_op()
local response_deadline = Sleep.sleep_op(30)
```

The suffix keeps possible actions visible in application code.

Fibers values are opaque library objects. Use their documented operations rather
than changing their Lua representation. Fibers protects its runtime stores and
validates supported transitions, but it does not attempt to sandbox trusted Lua
code or prevent deliberate mutation through `rawset`, `debug` or implementation
internals. Configuration which defines later runtime behaviour, such as a
Closure contract, is captured when the corresponding Lifetime is defined.

### `perform` resolves an option

`perform` submits an option to the runtime and is the explicit execution and suspension boundary.

```lua
local command = fibers.perform(commands:get_op())
```

The option may commit immediately, wait for other participants, or compose several actions into one transaction. Application code uses the same boundary in each case.

### Direct methods are the gentle on-ramp

Selected everyday facilities also provide a direct performing method:

```lua
local command = commands:get()
```

This is exactly:

```lua
local command = fibers.perform(commands:get_op())
```

Use the direct form for ordinary sequential fibre code. Ask for an option when
the action needs to join `choice`, `or_else`, sequencing or a product. The
facility method and the explicit form share one implementation and return the
same values and errors.

```lua
local outcome = fibers.perform(Op.choice(
  reply_ready:get_op(),
  stop_requested:get_op(),
  Sleep.sleep_op(30):map(function()
    return 'response deadline reached'
  end)
))
```

### Effects belong to committed worlds

An effect is a typed runtime obligation selected with an option and discharged only if that world commits. Fibers uses effects for task spawning, interruption, reactor control and other committed host work.

Most application code uses effects through ordinary facilities rather than constructing them directly. The important guarantee is that speculative alternatives do not start tasks or mutate the outside world merely because they were considered.

### Lifetimes account for continuing consequences

An `Op` describes a world which may commit. A Lifetime records what that world
leaves alive and who remains responsible for it. Task, Scope and resources are
narrow views of Lifetimes rather than separate custody systems.

Every structured task belongs to a Scope. The Scope is the ordinary capability
for admitting children; its underlying Lifetime accounts for those children and
retained resources before it closes.

```lua
fibers.run(function(scope)
  local map_task = scope:spawn(function()
    return load_map('Moon Garden')
  end, 'load-map')

  return fibers.perform(map_task:await_op())
end)
```

Options compose possible worlds. Lifetimes account for their continuing consequences.

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
local outcome = fibers.perform(Op.choice(
  voice_lines:get_op(),
  Sleep.sleep_op(1):wrap(function()
    return '[continue with subtitles]'
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
local admit_party = arena_places:take_op(#party.players):and_then(function()
  return match_lobby:put_op(party)
end)
```

The arena places are not consumed independently if the party cannot be admitted. Earlier communication and state changes remain provisional until the whole sequence commits.

Callbacks used by `map`, `and_then` and transactional resource transitions may be revisited during proof search. They must be deterministic, non-yielding and free of irreversible side effects.

### Two forms of conjunction

`all` combines requirements which must each be supportable without positive supply from their siblings:

```lua
Op.all({
  camera_channels:take_op(1),
  animation_channels:take_op(1),
})
```

The camera reservation cannot create a missing animation channel, or vice versa.

`tensor` permits compatible siblings to participate in an intentional transactional hand-off:

```lua
Op.tensor({
  cue_bus:inlet():write_op('GO'),
  cue_bus:outlet():read_some_op(2),
})
```

Both forms still commit as one coherent world. The distinction is whether sibling options may positively make one another possible.

A practical guide is:

| Situation | Use | Reason |
|---|---|---|
| Several requirements must each already be supportable | `all` | Siblings may constrain one another, but cannot supply missing readiness |
| One sibling deliberately hands state or a value to another | `tensor` | Compatible positive supply is part of the intended transaction |
| A put and take should rendezvous inside one decision | `tensor` | The producer is meant to make the consumer possible |
| You are unsure whether sibling supply is intended | `all` | It is the more conservative conjunction |

## The three callback phases

Fibers has three normative callback phases. A callback must obey the rules of the phase in which it is registered.

| Phase | Callbacks | Contract |
|---|---|---|
| 1. Speculative search | `guard`, `map`, `and_then`, resource transitions, effect `key` and `merge` | May run zero, one or several times. Must be deterministic, non-yielding and free of observable or irreversible side effects. |
| 2. Committed-world effect protocol | effect `prepare`, then `discharge` | `prepare` is pure and replayable. It may reject a candidate or return a discharge plan. `discharge` runs once, after state installation, and performs the committed host action. |
| 3. Participant continuation | `wrap` | Runs once when the selected participant resumes. It may perform further options and ordinary application work, but cannot alter the world which has already committed. |

A pure effect preparation must not reserve host capacity, mutate external state, deliver events, spawn, perform or yield. It may depend only on its payload, captured runtime configuration and managed facts already represented by the candidate. Put irreversible work in `discharge`, not `prepare`.

A guard delays algebraic elaboration until one structural occurrence becomes relevant. Its builder receives a deliberately narrow ephemeral activation view exposing only a stable monotonic activation instant and the current Scope; it must embed those values into the explicit residual `Op` it returns. The view is invalid once the builder returns. The residual is stable within that speculative activation, while a later activation may elaborate afresh. `Clock:after_op(d)` follows this rule by becoming `Clock:at_op(activation:now() + d)`. Use an effect for work belonging to the committed world, or `wrap` for work belonging to the resumed participant.

```lua
local show_selected_line = voice_lines:get_op():wrap(function(line)
  subtitle_panel:set_text(line)
  return line
end)
```

Typed effect identity is the pair of the effect-kind object and its raw Lua key. Types and object identity are preserved: `1` is distinct from `"1"`, and two distinct table keys remain distinct. `nil` is supported; NaN is rejected.

Task admission is an important effect example: a task whose admission option loses is never started. Most users encounter effects through tasks, scopes, interruption and host-backed resources. See [`docs/advanced/option-algebra.md`](docs/advanced/option-algebra.md) for the complete rules, including defeat obligations.

## Structured lifetimes

`fibers.run` creates a runtime and root scope. `fibers.spawn` starts a task in the current scope; `fibers.scope` creates a nested boundary.

```lua
local fibers = require('fibers')

fibers.run(function()
  local cinematic = fibers.spawn(function()
    return play_opening_cinematic()
  end, 'opening-cinematic')

  assert(fibers.perform(cinematic:await_op()) == 'completed')
end)
```

The raising forms `fibers.run` and `fibers.scope` return body values or raise after their boundaries have accounted for retained custody. `fibers.try_run` and `fibers.try_scope` return structured results instead. When Closure fails, the checked result retains an opaque recovery capability so the caller can inspect the error and explicitly retry or force the unresolved Closure.

The advanced Lifetime model has three laws: custody is the unique tree of responsibility, Grants provide non-custodial authority, and Closure resolves continuing consequences. Ordinary programmes can begin with tasks and scopes; systems code can state stronger transfer, Grant and Closure protocols where required.

See [`docs/advanced/lifetimes-and-custody.md`](docs/advanced/lifetimes-and-custody.md).

## Everyday facilities

The root `fibers` module is the lifecycle and contextual prelude: `run` establishes a root runtime and scope, while `perform`, `spawn`, `now`, protected calls and nested scopes operate within it. Types, constructors, option combinators and facilities live in their named modules.

### Channels

```lua
local channel = require('fibers.channel')

local commands = channel.new()
local buffered_events = channel.new(16)
```

Both forms expose `put_op` and `get_op` and compose with the same algebra.

### Transactional state

```lua
local Scalar = require('fibers.resource.scalar')
local state = Scalar.new('idle', 'state')

fibers.perform(state:expect_op('idle'):and_then(function()
  return state:write_op('running')
end))
```

Scalar also supports typed state-machine transitions for facilities whose rules should be defined once and reused.

### Notification, messaging and byte flow

`fibers.pulse` provides coalescing change notification. `fibers.mailbox` provides split sender and receiver endpoints, closure and selectable overflow policies.

`fibers.resource.flow` is the transactional byte-building block: it provides backpressure, exact and incrementally scanned delimiter reads, closure, data leases and producer-side capacity leases. `fibers.stream` builds readable, writable or duplex facilities from one or two Flows. Committed Flow changes notify host service through a deduplicated post-commit effect. All host-backed directions in one Runtime share one indexed poller and one lazily created reactor rather than allocating one task per direction.

### Pipes

Anonymous pipes are pairs of one-way Streams held in custody:

```lua
local file = require('fibers.file')
local reader, writer, err = fibers.perform(file.pipe_op())
assert(reader, err)

fibers.perform(writer:write_op('hello'))
fibers.perform(writer:close_op())
local bytes = fibers.perform(reader:read_all_op({ max = 4096 }))
```

Pipe acquisition occurs only after `pipe_op` commits. Newly created host handles
are immediately accountable to the current Lifetime until their permanent
Stream custody has been admitted. A private host hold covers the brief post-commit interval before Stream admission; it is not part of the public Lifetime model. See [`docs/guide/io.md`](docs/guide/io.md).

### Files

Regular-file and path operations are runtime-only and evented:

```lua
local fibers = require('fibers')
local file = require('fibers.file')
local Host = require('fibers.host')

fibers.run(function()
  local contents = assert(file.read_all('/etc/resolv.conf', {
    max = 64 * 1024,
  }))

  local output = assert(file.open('/tmp/example', 'w+b'))
  assert(output:write(contents))
  assert(output:flush())
  assert(output:sync())
  assert(output:close())
end, { host = Host.default() })
```

Each direct method performs a corresponding `_op`, and ordinary `_op` calls yield
their final value. Explicit `submit_*_op` forms return a `File.Job` held in custody or
`File.Request` with a selectable `result_op()`. Open files support exact reads
and separate `flush` from durable `sync`. `file.tmpfile()`
creates a named file held in exclusive custody, which is unlinked on close unless it is
renamed. Linux FFI hosts use `io_uring` when available. Other native hosts, and
Linux systems without a usable ring, use helper processes over evented pipes.
There is no synchronous pre-runtime file API. See
[`docs/guide/io.md`](docs/guide/io.md).

### Processes

Commands are captured, reusable descriptions; starting one creates a Process held in custody with
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
Process Closure closes stdin, requests graceful termination, escalates where
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
endpoints and pass through a resolver query held in custody:

```lua
local query = socket.resolve_name('example.org', 443)
local addresses, resolve_err = query:result()
assert(addresses, resolve_err)

local dial = socket.dial(addresses[1])
```

The ordinary named connection API consumes A and AAAA results incrementally and
runs staggered Happy Eyeballs v2 attempts. Attempt outcomes, DNS completions and
admission timers form one prioritised option expression over a transactional
race state:

```lua
local connection, report = socket.connect_name('example.org', 443)
assert(connection, report)
```

The winning Stream moves into the caller's scope. The call returns after every
losing query, Dial and Stream has closed. Resolver configuration, hosts data
and secure entropy are read through `fibers.file`, so the native DNS path does
not reintroduce synchronous file I/O. See
[`docs/guide/happy-eyeballs.md`](docs/guide/happy-eyeballs.md).

Accepted and connected Streams remain in the custody of their Listener or Dial
until one committed movement transfers the complete Stream subtree to the caller. Native Linux
FFI, luaposix and Nixio hosts provide non-blocking IPv4, IPv6 and Unix stream
sockets where the platform supports each family. Verified LuaJIT/cffi,
luaposix and Nixio hosts may expose a blocking `getaddrinfo` resolver and
advertise that limitation. Nixio also provides evented child processes through
a reaper process, with explicit capability limits for exec proof and descriptor
inheritance. See [`docs/guide/io.md`](docs/guide/io.md).

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
and Nixio bindings use the same host contract when those modules are present.
See [`docs/guide/io.md`](docs/guide/io.md).

### Time

```lua
fibers.perform(Sleep.sleep_op(0.25))
```

Timers are options, so timeouts require no separate cancellation mechanism.

Lower-level materials have canonical direct imports under their semantic owners: transactional resources under `fibers.resource.*`, Lifetime construction under `fibers.lifetime`, Grants under `fibers.grant`, Closure under `fibers.closure`, committed obligations under `fibers.effect`, and host observation protocols under `fibers.host.*`; there is no aggregate resource façade. Worked facilities are kept in [`examples/recipes/`](examples/recipes/) rather than expanding the principal API.

## Why the algebra goes further

Fibers is designed for readable application code, but its small surface carries stronger semantics than ordinary event selection.

- **Transactional continuation:** `and_then` can join several communications and state changes into one all-or-nothing protocol.
- **Certified priority:** `or_else` distinguishes a genuine proof of present absence from incomplete search.
- **Two conjunctions:** `all` and `tensor` distinguish joint requirements from intentional transactional hand-off.
- **Occurrence-sensitive commitment:** wraps, effects and defeat obligations belong to precise dynamic option occurrences.
- **Cross-resource decisions:** communication, state, external observations, custody changes and selected consequences can participate in one coherent commit.

The implementation searches for a compatible resource world, validates the facts on which that world depends, and commits it through one serial authority. A separate repository-local reference evaluator runs the same semantic test corpus using a simpler strategy.

Readers interested in CSP, Concurrent ML, Transactional Events, Reagents or transactional memory may wish to begin with:

- [`docs/design/comparison.md`](docs/design/comparison.md)
- [`docs/advanced/option-algebra.md`](docs/advanced/option-algebra.md)
- [`docs/design/kernel.md`](docs/design/kernel.md)
- [`reference/README.md`](reference/README.md)

The project does not presently claim a denotational semantics, a mechanised proof, a published encoding result, fairness for unordered choice, or lock-free parallel commit. The comparison document states the present strengths and limits directly.

## Intended uses

Fibers is intended for programmes whose concurrent behaviour should remain
readable as it becomes more exact. This includes firmware and control software,
robotics, emergency and field systems, network services, highly concurrent
desktop applications, simulations, embedded plugin logic, and ambitious games
and interactive worlds—especially where interruption, cancellation, resource
lifetime and failure boundaries need to remain visible.

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

Luau has a distinct loader and host-integration path. The source tree includes an experimental Roblox embedded driver and signal adapter; Wally/Rojo packaging and real-Studio smoke testing remain release work. Native host facilities also depend on the selected environment. See [`docs/contributing/compatibility.md`](docs/contributing/compatibility.md) for the current policy and verification commands.

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
- [Fibers for Roblox](docs/guide/roblox.md)
- [Gameplay examples](examples/gameplay/README.md)
- [Pipes and sockets](docs/guide/io.md)
- [Non-blocking DNS](docs/guide/dns.md)
- [Happy Eyeballs v2](docs/guide/happy-eyeballs.md)
- [Tutorial and embedding examples](examples/README.md)
- [Facility recipes](examples/recipes/README.md)

### Understanding the design

- [Option algebra](docs/advanced/option-algebra.md)
- [Lifetimes: custody, Grants and Closure](docs/advanced/lifetimes-and-custody.md)
- [Flows, streams and the host reactor](docs/advanced/flows-and-streams.md)
- [Embedding and host integration](docs/advanced/embedding.md)
- [Port architectures: Rust, Embassy, WASM and Kotlin](docs/advanced/ports.md)
- [Comparison with related systems](docs/design/comparison.md)
- [Kernel design](docs/design/kernel.md)

### Extending and contributing

- [Facility authoring](docs/advanced/facility-authoring.md)
- [Parallel ledger kernel](docs/design/ledger-kernel.md)
- [Trusted resource programmes](docs/contributing/trusted-resource-programmes.md)
- [Repository layout](docs/contributing/repository-layout.md)
- [Lua compatibility](docs/contributing/compatibility.md)
- [Test profiles](docs/contributing/testing.md)
