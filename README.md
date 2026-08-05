# Fibers

Transactional concurrency and accountable lifetimes for Lua and Luau.

Fibers lets a programme describe possible concurrent actions, combine those descriptions in ordinary Lua, and perform one coherent result.

The same small vocabulary applies to:

* communication;
* time;
* transactional state;
* tasks and scopes;
* custody and authority;
* files, streams, sockets and processes;
* embedded hosts and game engines.

Fibers version 1 is an advanced work in progress. Its public surface is being reduced and settled before the first release.

## Begin with sequential fibre code

Fibres run ordinary Lua functions. Everyday facilities provide direct methods, so routine fibre code can be read from top to bottom:

```lua
local fibers = require('fibers')
local channel = require('fibers.channel')

local commands = channel.new()
local results = channel.new()

fibers.run(function()
  fibers.spawn(function()
    local command = commands:get()
    results:put('completed ' .. command)
  end)

  commands:put('refresh configuration')
  print(results:get())
end)
```

`fibers.spawn` starts the worker in the current scope.

The direct `get` and `put` methods perform their actions in place. They suspend only when another participant or future event is required.

## Compose the same actions when needed

Each direct method has an inert `_op` form.

The direct form performs an action:

```lua
local command = commands:get()
```

The `_op` form describes the same action without performing it:

```lua
local get_command = commands:get_op()
```

Descriptions can be combined before one coherent result is selected:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local channel = require('fibers.channel')

local commands = channel.new()
local acknowledgements = channel.new()
local stop_requests = channel.new()

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(
      commands:get_op():and_then(
        Op.guard(function(command)
          return acknowledgements:put_op(
            'completed ' .. command
          )
        end)
      )
    )
  end)

  local do_work = commands:put_op('refresh state')
    :and_then(acknowledgements:get_op())
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

Both alternatives describe complete exchanges. Their communications and state changes remain provisional until `perform` selects one coherent result.

The runnable progression begins with:

* [`examples/tutorial/00_getting_started.lua`](examples/tutorial/00_getting_started.lua)
* [`examples/tutorial/01_direct_methods_and_options.lua`](examples/tutorial/01_direct_methods_and_options.lua)
* the complete [example index](examples/README.md)

## The model

Two ideas organise the system:

1. **Options** describe worlds which may commit.
2. **Lifetimes** account for what those worlds leave alive.

A small set of practical rules is enough to begin.

### Fibres are ordinary sequential code

A fibre is a cooperatively scheduled Lua function.

Within a fibre, code remains direct and sequential:

```lua
fibers.spawn(function()
  local command = commands:get()
  apply_command(command)
end)
```

Fibers does not require ordinary application code to be expressed as callbacks, promises or explicit state machines.

### Options describe possible actions

An option is an inert description of an action which may form part of a coherent result.

In this documentation, **option** is the concept. `Op` is the Lua type representing it.

Methods ending in `_op` return options:

```lua
local receive_command = commands:get_op()
local reach_deadline = Sleep.sleep_op(30)
```

Constructing either value has no external effect.

An option may describe:

* an immediately available result;
* one communication;
* several communications;
* provisional state changes;
* a deadline;
* the admission of continuing work;
* movement of custody;
* a complete multi-party transaction.

Fibers values are opaque library objects. Use their documented operations rather than changing their Lua representation.

### `perform` selects and commits one result

```lua
local command = fibers.perform(commands:get_op())
```

`perform` submits an option to the runtime.

The option may:

* commit immediately;
* wait for another participant;
* wait for a future event;
* combine several actions into one transaction;
* recruit other current participants;
* start or transfer continuing work.

Application code uses the same `perform` boundary in each case.

`perform` is a possible suspension point, not an instruction to suspend. An option which can commit immediately allows the fibre to continue immediately.

### Direct methods perform their `_op` forms

For supported facilities:

```lua
local command = commands:get()
```

means exactly:

```lua
local command = fibers.perform(commands:get_op())
```

Use direct methods for ordinary sequential fibre code.

Ask for an option when the action must participate in:

* `choice`;
* `and_then`;
* `or_else`;
* `each`;
* `together`;
* a larger application-defined operation.

The direct and option forms share one implementation and return the same values and errors.

### Lifetimes account for continuing consequences

An option describes a world which may commit.

A Lifetime records what that world leaves alive and who remains responsible for it.

Tasks, scopes and retained resources are views of the same lifetime system rather than separate ownership conventions.

```lua
fibers.run(function(scope)
  local task = scope:spawn(function()
    return load_map('Moon Garden')
  end)

  return task:await()
end)
```

Options compose possible actions. Lifetimes account for their continuing consequences.

## A small algebra

In Fibers, an algebra is simply a small set of ways to combine options. No formal background is required.

The important property is that the same combinations retain their meanings across channels, state, tasks, ownership and host resources.

| Expression          | Read it as                                        |
| ------------------- | ------------------------------------------------- |
| `Op.always(value)`  | this result is already available                  |
| `Op.never()`        | this option cannot succeed                        |
| `Op.choice(a, b)`   | either coherent result is acceptable              |
| `a:and_then(b)`     | satisfy `a`, then `b`, in one transaction         |
| `a:or_else(b)`      | use `a` if it can happen now; otherwise use `b`   |
| `Op.each(a, b)`     | satisfy both, with each standing on its own       |
| `Op.together(a, b)` | satisfy both, allowing compatible sibling support |
| `a:map(f)`          | transform provisional results                     |
| `a:wrap(f)`         | run participant-local code after commitment       |
| `Op.guard(f)`       | construct the next option from provisional values |

Most programmes can begin with:

* direct facility methods;
* `perform`;
* `choice`;
* `and_then`;
* `or_else`;
* `spawn`;
* tasks and scopes.

`each` and `together` become useful when several requirements must form one decision.

## `choice`: either result is acceptable

```lua
local outcome = fibers.perform(Op.choice(
  voice_lines:get_op(),
  Sleep.sleep_op(1):map(function()
    return '[continue with subtitles]'
  end)
))
```

Either result is permitted.

Source order does not make the first branch a priority. If several alternatives can commit, Fibers may select any permitted result.

The alternatives may themselves describe complete multi-step actions:

```lua
local complete_work = commands:put_op('refresh state')
  :and_then(acknowledgements:get_op())

local stop = stop_requests:get_op()

local result = fibers.perform(Op.choice(
  complete_work,
  stop
))
```

If `stop` is selected, the command exchange has not partly happened. Losing alternatives make no committed changes.

## `and_then`: one transactional sequence

```lua
local admit_party = arena_places:take_op(#party.players)
  :and_then(match_lobby:put_op(party))
```

This means:

> Reserve enough arena places, then place the party in the lobby, as one transaction.

The arena capacity is not consumed independently if the party cannot also be admitted.

Earlier communication and state changes remain provisional until the complete sequence succeeds.

When the next option depends on provisional values, use `Op.guard`:

```lua
local handle_command = commands:get_op():and_then(
  Op.guard(function(command)
    return acknowledgements:put_op(
      'completed ' .. command
    )
  end)
)
```

The command and acknowledgement form one coherent exchange.

`and_then` supports protocols such as:

* reserve and publish;
* receive and validate;
* acquire several related resources;
* read state and conditionally update it;
* admit a task only as part of a larger successful decision;
* transfer responsibility together with the action which justifies it.

## `or_else`: act now or fall back

```lua
local result = fibers.perform(
  preferred:or_else(fallback)
)
```

This means:

> Use the preferred option if it can happen now; otherwise consider the fallback.

“Can happen now” means that a coherent transaction satisfying the preferred option can commit without waiting for a future change.

That transaction may involve:

* another currently participating fibre;
* an alternative offered by that participant;
* several communications;
* provisional state changes;
* transactional task admission;
* compatible parts of a product.

Fibers does not reduce “now” to a local readiness flag or a brief polling interval.

For example:

```lua
local action = attack_op(agent, target)
  :or_else(take_cover_op(agent))
  :or_else(return_to_patrol_op(agent))
```

This can be read directly:

1. attack if an attack can happen now;
2. otherwise take cover if that can happen now;
3. otherwise return to patrol.

Each level may describe a substantial transaction. The priority law remains the same.

A timeout is a different statement and should be written as one:

```lua
local result = fibers.perform(Op.choice(
  request:reply_op(),
  Sleep.sleep_op(5):map(function()
    return nil, 'deadline reached'
  end)
))
```

`or_else` concerns present possibility. A timer concerns the passage of time.

A bounded host may divide the runtime’s work across several driver turns. Fibers does not mistake unfinished internal work for absence, so an execution budget does not silently permit the fallback.

## `each`: all requirements stand on their own

```lua
local reservations = Op.each({
  camera_channels:take_op(1),
  animation_channels:take_op(1),
})
```

Every lane must succeed.

The lanes share one transaction and may constrain one another through common state, but one lane cannot supply readiness missing from another.

The camera reservation cannot create a missing animation channel, or vice versa.

Use `each` when every requirement must be independently supportable.

Examples include:

* reserving one camera channel and one animation channel;
* obtaining several permissions;
* updating several independently available resources;
* completing several externally supported exchanges as one decision.

## `together`: all requirements may support one another

```lua
local handoff = Op.together({
  cue_bus:inlet():write_op('GO'),
  cue_bus:outlet():read_some_op(2),
})
```

Every lane must succeed, but compatible siblings may make one another possible.

Here the write is intended to supply the read. Both commit as one coherent result.

Use `together` for:

* an internal put and take;
* movement of capacity between lanes;
* coordinated ownership transfer;
* cyclic exchanges;
* multi-party hand-offs;
* transactions whose parts deliberately complete one another.

The practical distinction is:

| Question                                                                | Use        |
| ----------------------------------------------------------------------- | ---------- |
| Must every lane be supportable without positive help from its siblings? | `each`     |
| May compatible lanes deliberately make one another possible?            | `together` |

Both operators are conjunctions. They differ only in whether sibling supply is part of the intended transaction.

## When callbacks run

Fibers distinguishes code which helps describe a possible world from code which runs after that world has committed.

### `map` transforms provisional values

```lua
local labelled_reply = replies:get_op():map(function(reply)
  return 'reply: ' .. reply
end)
```

A `map` callback helps define the result of a candidate transaction.

It may be revisited while Fibers considers alternatives. It must therefore be:

* deterministic;
* non-yielding;
* free of irreversible or externally visible side effects.

### `guard` constructs a provisional continuation

```lua
local reply = requests:get_op():and_then(
  Op.guard(function(request)
    return responses:put_op(handle(request))
  end)
)
```

The guard receives provisional values and returns the next option.

Like `map`, its callback belongs to the description of the possible transaction and may be revisited.

A root guard receives no arguments. Beneath `and_then`, the guard receives the preceding provisional results directly as Lua varargs.

### `wrap` runs after commitment

```lua
local selected_line = voice_lines:get_op():wrap(function(line)
  subtitle_panel:set_text(line)
  return line
end)
```

A `wrap` callback runs when the selected participant resumes after commitment.

It may:

* update ordinary application objects;
* log;
* perform further options;
* spawn work;
* call application code.

It cannot alter the transaction which has already committed.

### The application rule

Use:

* `map` and `guard` to describe possible results;
* `wrap` for ordinary work after selection.

Fibers rejects several invalid phase crossings, including performing, yielding or spawning from speculative callbacks.

Lua cannot prevent every accidental side effect in trusted callback code. Ordinary Lua tables and globals are not transactional merely because they are accessed from a Fibers callback.

## Effects belong to committed worlds

An effect is a typed runtime obligation selected with an option and discharged only if that world commits.

Fibers uses effects for such work as:

* task admission;
* interruption;
* reactor control;
* host-resource operations.

Effect handling has two phases:

1. `prepare` validates and plans the committed work without changing the host.
2. `discharge` performs the irreversible action after managed state has been installed.

Speculative alternatives therefore do not start tasks or mutate the outside world merely because they were considered.

Most application code uses effects through ordinary facilities rather than constructing effect kinds directly.

Task admission is an important example: a task whose admission option loses is never started.

See:

* [`docs/advanced/option-algebra.md`](docs/advanced/option-algebra.md)
* [`examples/tutorial/13_typed_effects.lua`](examples/tutorial/13_typed_effects.lua)

## Structured lifetimes

`fibers.run` creates a runtime and root scope.

`fibers.spawn` starts a task in the current scope.

`fibers.scope` creates a nested lifetime boundary.

```lua
local fibers = require('fibers')

fibers.run(function()
  local cinematic = fibers.spawn(function()
    return play_opening_cinematic()
  end)

  assert(cinematic:await() == 'completed')
end)
```

A structured task is not merely a scheduled function. It is continuing work for which some Lifetime remains responsible.

### Scopes account for their children

A scope does not finish successfully while retained child work remains unaccounted for.

The raising forms:

```lua
fibers.run(...)
fibers.scope(...)
```

return body values or raise after their boundaries have accounted for retained custody.

The checked forms:

```lua
fibers.try_run(...)
fibers.try_scope(...)
```

return structured results instead.

When Closure fails, the checked result retains an opaque recovery capability so that unresolved responsibility can be inspected and explicitly retried or forced.

### Nursery and supervisor policies are explicit

The root scope follows nursery semantics.

A nursery:

* propagates failed child work;
* requests closure of remaining siblings;
* accounts for all retained work before leaving the boundary.

Supervisor scopes can instead apply an explicit policy, including collecting child failures or allowing them not to determine the boundary status.

Failure policy therefore belongs to the scope which owns the work.

### Cancellation is cooperative

A fibre observes cancellation when it reaches a cooperating Fibers operation or another recognised cancellation point.

Fibers cannot safely pre-empt:

* an infinite CPU loop;
* a blocking foreign call;
* non-cooperative host code;
* application code which never reaches a suspension point.

Closure guarantees accounting. It does not manufacture pre-emption which the host cannot provide.

## Custody, Grants and Closure

Most programmes can use tasks and scopes without manipulating the advanced Lifetime model directly.

Systems which need explicit ownership and authority can use three distinct concepts.

### Custody is responsibility

Every live Lifetime has one custodial parent.

Custody answers:

> Who is responsible for ensuring that this continuing consequence eventually closes?

The custody relation is a tree. Responsibility is unique.

Retaining a Lua reference does not create custody.

### Grants are authority

A Grant answers:

> Who is authorised to perform which operations on this Lifetime or resource?

Authority and responsibility are deliberately separate.

Several parties may hold compatible Grants while custody remains with one parent.

Grant rights are explicit. Transferability and authority to regrant are not implied.

### Closure resolves continuing consequences

Closure is the process by which a Lifetime and everything beneath it reach a terminal state.

Its public guarantees include:

* closure progresses monotonically;
* closure requests travel from parent to child;
* successful completion travels from child to parent;
* a parent does not report successful closure while descendants remain unresolved;
* successful partial progress is retained;
* unresolved closure remains represented as an outstanding responsibility;
* recovery may retry or force the retained unresolved work.

A task body result and the complete Lifetime outcome are related but distinct facts.

For example:

* a task body may return while a retained stream remains open;
* a connection attempt may fail as a domain result while closing correctly;
* a task body may succeed while resource Closure later fails;
* a body failure may remain primary while cleanup failure is also retained.

See [Lifetimes: custody, Grants and Closure](docs/advanced/lifetimes-and-custody.md).

## Diagnostics and execution contracts

Fibers programmes do not need user-assigned names to operate correctly. The runtime assigns stable internal identities automatically.

Long-lived tasks, scopes, resources and important application operations may also carry optional human-readable labels.

### Labels add human context

```lua
local commands = channel.new(16)
  :label('service-commands')

local worker = fibers.spawn(run_worker)
  :label('configuration-watcher')
```

A diagnostic can then describe the programme in application terms:

```text
task "configuration-watcher"
is waiting on resource "service-commands"
```

Labels are:

* optional;
* non-unique;
* semantically inert;
* separate from stable runtime identity.

They do not affect:

* matching;
* equality;
* scheduling;
* custody;
* authority;
* commitment.

A label may be changed or cleared with `:label(nil)`.

Most local values need no label. Labels are most useful for:

* long-lived coordinators;
* service and supervision boundaries;
* resources which will appear in diagnostics;
* important application-level options;
* host resources with meaningful operational roles.

### Options may also be labelled

Options are immutable values. Labelling one therefore returns a new option and leaves the original unchanged:

```lua
local receive = commands:get_op()

local primary = receive
  :label('receive-primary-command')

local fallback = receive
  :label('receive-fallback-command')
```

Labels may identify either a whole application operation or selected internal parts:

```lua
local admit_request =
  capacity:take_op(1)
    :label('reserve-capacity')
    :and_then(
      requests:put_op(request)
        :label('publish-request')
    )
    :label('admit-request')
```

These annotations remain outside the algebra. They give diagnostics and instrumentation vocabulary for explaining what the programme was trying to do.

### Suspension-free regions

Some programmes use a coordinator discipline:

1. wait for one event;
2. reduce it to a new quiescent state without interleaving;
3. return to the outer blocking `perform`.

Fibers can enforce that scheduling contract:

```lua
local coordinator = fibers.spawn(function()
  while true do
    local event = fibers.perform(
      next_event_op(state)
        :label('device.next-event')
    )

    fibers.without_suspension(function()
      reduce_event(state, event)
    end)
  end
end):label('device-coordinator')
```

`fibers.without_suspension(fn, ...)` requires the function to begin and finish without the current fibre relinquishing execution.

It:

* preserves all return values, including nils;
* preserves ordinary Lua errors;
* may be nested;
* permits options which commit without suspension.

The assertion concerns actual suspension, not the presence of `perform` in the call tree:

```lua
fibers.without_suspension(function()
  local value = fibers.perform(
    preferred:or_else(Op.always(default))
  )

  apply_immediate_result(value)
end)
```

If an operation would:

* park the current fibre;
* allow another application fibre to run first;
* return control because the configured search budget was exhausted;

Fibers raises a `suspension_error` before that hand-off.

Available task, option and resource labels are included in the diagnostic.

`without_suspension` is an execution assertion. It is not:

* a transaction;
* a lock;
* rollback for ordinary Lua mutation;
* a time limit;
* protection against a foreign call which blocks without returning to Fibers.

It ensures that a dynamic region remains within one uninterrupted fibre turn. The same scheduler boundary also gives instrumentation a precise unit for identifying code which retains execution for too long.

## Everyday facilities

The root `fibers` module is the lifecycle and contextual prelude.

`run` establishes a root runtime and scope. Within that runtime, the root module provides such operations as:

* `perform`;
* `spawn`;
* nested scopes;
* protected calls;
* `without_suspension`;
* runtime time.

Types, constructors, option combinators and facilities live in their named modules.

### Channels

```lua
local channel = require('fibers.channel')

local commands = channel.new()
local buffered_events = channel.new(16)
local unbounded_events = channel.new(math.huge)
```

Channels expose direct `put` and `get` methods together with composable `put_op` and `get_op` forms.

All channel forms participate in the same algebra.

### Transactional state

```lua
local Cell = require('fibers.resource.cell')

local state = Cell.new('idle')

fibers.perform(
  state:expect_op('idle')
    :and_then(state:write_op('running'))
)
```

The expectation and write commit together.

Cell also supports waiting and projection:

```lua
local running = state:wait_until(function(value)
  return value == 'running'
end)

local description = state:match(function(value)
  if value == 'running' then
    return true, 'state:' .. value
  end
end)
```

`wait_until` returns the complete satisfying value.

`match` waits for a matcher whose first return value is truthy, then returns its remaining projected values.

Their `_op` forms compose with choices, products and transactional sequencing.

Cell also supports typed state-machine transitions for facilities whose rules should be defined once and reused.

### Notification and messaging

`fibers.pulse` provides coalescing change notification.

`fibers.mailbox` provides:

* split sender and receiver endpoints;
* closure;
* selectable overflow policies.

### Flows and streams

`fibers.resource.flow` is the transactional byte-flow building block.

It provides:

* backpressure;
* exact reads;
* incremental delimiter scanning;
* closure;
* data leases;
* producer-side capacity leases.

`fibers.stream` builds portable readable, writable and duplex streams from one or two Flows without importing host I/O.

`fibers.io.stream` adds transactional host-handle opening.

Committed Flow changes notify host service through a deduplicated post-commit effect.

The indexed reactor publishes bounded host-owned offers for:

* accepted connections;
* connection completions;
* received datagrams.

All host-backed directions and offer sources in one Runtime share one poller and one lazily created reactor rather than allocating one task per registration.

See [Flows, streams and the host reactor](docs/advanced/flows-and-streams.md).

### Pipes

Anonymous pipes are pairs of one-way Streams held in custody:

```lua
local file = require('fibers.file')

local reader, writer, err =
  fibers.perform(file.pipe_op())

assert(reader, err)

fibers.perform(writer:write_op('hello'))
fibers.perform(writer:close_op())

local bytes = fibers.perform(
  reader:read_all_op({ max = 4096 })
)

assert(bytes == 'hello')
```

Pipe acquisition occurs only after `pipe_op` commits.

New host handles are immediately accountable to the current Lifetime until their permanent Stream custody has been admitted.

A private host hold covers the brief post-commit interval before Stream admission. It is not part of the public Lifetime model.

See [Pipes, files, sockets and processes](docs/guide/io.md).

### Files

Regular-file and path operations are runtime-only and evented:

```lua
local fibers = require('fibers')
local file = require('fibers.file')
local AutoIO = require('fibers.io.auto')

fibers.run(function()
  local contents = assert(file.read_all(
    '/etc/resolv.conf',
    { max = 64 * 1024 }
  ))

  local output = assert(
    file.open('/tmp/example', 'w+b')
  )

  assert(output:write(contents))
  assert(output:flush())
  assert(output:sync())
  assert(output:close())
end, {
  host = AutoIO.default(),
})
```

Each direct method performs a corresponding `_op`.

Ordinary `_op` calls yield their final value.

Explicit `submit_*_op` forms return a `File.Job` held in custody or a `File.Request` with a selectable `result_op()`.

Open files support:

* exact reads;
* separate buffered `flush`;
* durable `sync`;
* jobs and selectable requests.

`file.tmpfile()` creates a named file held in exclusive custody. It is unlinked on close unless renamed.

Linux FFI hosts use `io_uring` when available. Other native hosts, and Linux systems without a usable ring, use helper processes over evented pipes.

There is no synchronous pre-runtime file API.

See [Pipes, files, sockets and processes](docs/guide/io.md).

### Processes

Commands are captured, reusable descriptions.

Starting one creates a Process held in custody, with ordinary Fibers Streams for configured standard input and output:

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

`launch_op()` uses a guard to construct a fresh Process at synchronisation time. Its committed supervisor effect performs the irreversible host launch.

`start()` is the direct launch-and-handshake convenience.

`result_op()` can participate in the option algebra and becomes available only after the child has been reaped.

Process Closure:

* closes standard input;
* requests graceful termination;
* escalates where required;
* retains signal, reap or close failure.

See [Pipes, files, sockets and processes](docs/guide/io.md).

### Sockets and name resolution

Listeners accept duplex Streams.

An outbound `Dial` separates starting a connection attempt from observing or composing its eventual result:

```lua
local socket = require('fibers.socket')

local listener = assert(
  socket.listen_ipv4('127.0.0.1', 8080)
)

local dial = socket.dial(
  socket.ipv4_address('127.0.0.1', 8080)
)

local connection, err = dial:result()
```

IPv4, IPv6 and Unix addresses are explicit values.

Host names are unresolved endpoints and pass through a resolver query held in custody:

```lua
local query = socket.resolve_name(
  'example.org',
  443
)

local addresses, resolve_err = query:result()
assert(addresses, resolve_err)

local dial = socket.dial(addresses[1])
```

The named connection API consumes A and AAAA results incrementally and runs staggered Happy Eyeballs v2 attempts.

Attempt outcomes, DNS completions and admission timers form one prioritised option expression over transactional race state.

Destination ordering comes from a required host or application policy. Bounded hosts may combine an explicit active-attempt limit with a per-attempt timeout so black-holed sockets release capacity:

```lua
local endpoint =
  socket.name_endpoint('example.org', 443)

local connection, report = socket.connect(
  endpoint,
  {
    order_destinations =
      application_destination_order,
  }
)

assert(connection, report)
```

The winning Stream moves into the caller’s scope.

The call returns after every losing query, Dial and Stream has closed.

Resolver configuration, hosts data and secure entropy are read through `fibers.file`, so the native DNS path does not reintroduce synchronous file I/O.

Accepted and connected Streams remain in the custody of their Listener or Dial until one committed movement transfers the complete Stream subtree to the caller.

Native Linux FFI, luaposix and Nixio hosts provide non-blocking IPv4, IPv6 and Unix stream sockets where the platform supports each family.

Verified LuaJIT/cffi, luaposix and Nixio hosts may expose a blocking `getaddrinfo` resolver and advertise that limitation.

Nixio also provides evented child processes through a reaper process, with explicit capability limits for execution proof and descriptor inheritance.

See:

* [Non-blocking DNS](docs/guide/dns.md)
* [Happy Eyeballs v2](docs/guide/happy-eyeballs.md)
* [Pipes, files, sockets and processes](docs/guide/io.md)

### Datagrams

UDP sockets preserve message boundaries and source addresses rather than pretending to be byte Streams:

```lua
local socket = require('fibers.socket')

local udp = assert(
  socket.udp_ipv4('0.0.0.0', 0)
)

udp:send_to(
  'hello',
  socket.ipv4_address('192.0.2.10', 9000)
)

udp:flush()

local packet, receive_err = udp:receive_from({
  max_size = 4096,
})
```

`send_to_op` admits one indivisible message to a bounded outbound queue.

`flush_op` observes completion of messages admitted before it was constructed. It does not imply remote delivery.

Incoming queues are bounded.

Received records retain:

* the peer address;
* truncation status;
* original size where the host can report it.

Native Linux FFI hosts support IPv4 and IPv6 UDP. Luaposix and Nixio bindings use the same host contract when those modules are present.

See [Pipes, files, sockets and processes](docs/guide/io.md).

### Time

```lua
fibers.perform(Sleep.sleep_op(0.25))
```

Timers are options, so timeouts require no separate cancellation mechanism.

Lower-level materials have canonical direct imports under their semantic owners:

* transactional resources under `fibers.resource.*`;
* Lifetime construction under `fibers.lifetime`;
* Grants under `fibers.grant`;
* Closure under `fibers.closure`;
* committed effects under `fibers.effect`;
* embedding protocols under `fibers.embed.*`;
* host observation and I/O under `fibers.io.*`.

There is no aggregate resource façade.

Worked facilities are kept in [`examples/recipes/`](examples/recipes/) rather than continually expanding the principal API.

## Embedding Fibers

Fibers can own an application’s event loop through `fibers.run`, or be driven incrementally by an embedding host.

The embedding interface distinguishes such states as:

* a transaction committed;
* host readiness is required;
* more bounded search work is required;
* runnable work was started;
* the runtime is quiescent;
* the runtime is idle.

A bounded host can therefore advance Fibers within:

* a game frame;
* a firmware control cycle;
* a plugin callback;
* a foreign C, C++ or Rust event loop;
* an engine scheduling phase.

See [Embedding and host integration](docs/advanced/embedding.md).

### Luau and Roblox

Luau has a separate loader and host-integration path.

The experimental `fibers.roblox` adapter provides:

* bounded `prepare` and `advance` integration;
* RunService-phase scheduling;
* signal subscriptions held under Lifetime custody;
* root shutdown handling.

See:

* [Fibers for Roblox](docs/guide/roblox.md)
* [`examples/roblox/`](examples/roblox/)
* [Gameplay examples](examples/gameplay/README.md)

Wally and Rojo packaging, together with real-Studio smoke testing, remain release work.

## How Fibers preserves these semantics

Ordinary application code does not need to understand the execution kernel.

This section describes why the public laws continue to hold when several fibres, resources and possible transactions interact.

### Coherent committed worlds

An option describes one or more worlds which could commit.

A world may include:

* selected communications;
* provisional state changes;
* several participating fibres;
* task admission;
* custody movement;
* committed host obligations;
* participant results.

Fibers searches for a world in which all selected requirements are mutually compatible.

Nothing in a losing or incomplete world is committed.

### Speculative state and rollback

The runtime maintains provisional resource state while considering alternatives.

A first-write journal records enough information to restore the earlier world when a candidate fails or another branch is considered.

This avoids copying the complete runtime state for every alternative while preserving all-or-nothing commitment.

### Participant recruitment

A transaction may require other currently participating fibres.

Fibers recruits only participants connected to the candidate operation rather than considering arbitrary runtime-wide subsets.

A recruited participant may itself offer several alternatives. The kernel can backtrack when an initial partner or branch cannot complete the whole world.

### Exchange matching

Transactions may contain several producers, consumers, capacities or transfers.

The kernel uses compatibility checks and matching analysis to determine whether all requirements can be satisfied together.

This includes detection of cases where every individual requirement appears plausible but no complete matching exists.

`each` and `together` use distinct visibility rules so that their public meanings remain separate.

### Present possibility and `or_else`

To honour:

> Use the preferred option if it can happen now; otherwise use the fallback,

Fibers determines whether any presently committable world satisfies the preferred side.

When none does, the runtime records the managed facts supporting that conclusion.

If a relevant fact changes, the conclusion is invalidated and reconsidered. Unrelated changes do not require indiscriminate re-search.

### Bounded search without weakened semantics

An embedding host may limit how much internal work Fibers performs in one driver turn.

When that allowance is exhausted, Fibers retains the actual search:

* the Lua search stack;
* provisional activations;
* matching cursors;
* rollback position;
* relevant frontier state.

It resumes later rather than restarting from the beginning.

An incomplete bounded search is not treated as evidence that the preferred side of `or_else` cannot happen.

Host budgets therefore do not silently change programme meaning.

### Committed effects

Some selected worlds require an external action, such as:

* admitting a task;
* registering host readiness;
* launching a process;
* delivering an interruption;
* updating a host facility.

Fibers represents these as typed committed effects.

Effect preparation is pure and may validate or merge the planned work.

Discharge occurs only after the managed state of the selected world has been installed.

Speculative alternatives therefore do not start tasks or mutate the host merely because they were considered.

### One commit authority

Candidate validation, managed-state installation and committed-effect discharge pass through one serial commit authority.

Fibers does not presently claim parallel lock-free commitment.

### Reference and conformance testing

The repository includes a smaller exhaustive evaluator for finite closed option expressions.

It is deliberately separate from the production kernel’s scheduler, rollback journal and matching implementation.

Conformance tests compare the production execution frontier with this reference model across generated transaction shapes.

Readers interested in CSP, Concurrent ML, Transactional Events, Reagents or transactional memory may wish to read:

* [Comparison with related systems](docs/design/comparison.md)
* [Option algebra](docs/advanced/option-algebra.md)
* [Kernel design](docs/design/kernel.md)
* [Execution frontiers](docs/design/execution-frontiers.md)

The project does not presently claim:

* a denotational semantics;
* a mechanised correctness proof;
* a published encoding result;
* fairness for unordered choice;
* lock-free parallel commitment.

## Intended uses

Fibers is intended for programmes whose concurrent behaviour should remain readable as it becomes more exact.

This includes:

| Domain                          | Example                                                                                           |
| ------------------------------- | ------------------------------------------------------------------------------------------------- |
| Firmware and controllers        | read a sensor, meet a deadline and leave actuators in a safe state                                |
| Robotics and autonomy           | reserve motion and perception capacity, then admit one coherent trajectory                        |
| Emergency and field systems     | confirm a hazard, reserve communications and dispatch a connected response unit                   |
| Desktop and server applications | admit work, supervise background services and retain failed shutdown as an outstanding obligation |
| Games, Luau and Roblox          | coordinate players, scenes, AI intentions, camera custody and game mechanics                      |
| Embedded plugin hosts           | expose bounded host resources while guest logic remains under explicit custody and Closure        |

The same expression can be read at two levels:

* as a direct description of what the programme should do;
* as a precise statement about which actions may commit together.

Fibers coordinates work within one cooperative runtime domain.

It is not:

* a durable database;
* a distributed transaction system;
* a source of CPU parallelism;
* a substitute for process or hardware fault containment;
* a means of forcibly interrupting non-cooperative foreign code.

## Project status and compatibility

Fibers version 1 is an advanced work in progress.

The core algebra, execution-frontier runtime, transactional resource substrate and Lifetime model are substantial. The public API, packaging and complete platform verification are still being settled.

Production source uses the Lua 5.1 grammar.

The development matrix covers:

```text
Lua 5.1, 5.2, 5.3, 5.4 and 5.5
LuaJIT v2.1
Luau
```

Luau has a distinct loader and host-integration path.

Native host facilities depend on the selected environment.

See [Lua compatibility](docs/contributing/compatibility.md) for the current support policy and verification commands.

## Packages and profiles

The source distinguishes:

* `fibers-core`;
* host-neutral `fibers-io`;
* shared `fibers-io-linux` bindings;
* explicit `fibers-io-<backend>` implementations;
* the separate `fibers-roblox` integration.

Automatic native probing is confined to `fibers.io.auto`.

Constrained builds can select exact module roots and emit a reduced tree or bundle with:

```sh
scripts/build-profile.lua
```

See [Packages, profiles and embedding](docs/design/packages-and-embedding.md).

## Getting started

From a repository checkout:

```sh
make test
make examples
```

Run the opening example with an available Lua interpreter:

```sh
lua5.4 examples/tutorial/00_getting_started.lua
```

Until the first packaged release, add `src` to the Lua module path or vendor `src/fibers` with the application.

Begin with:

* [Programming guide](docs/guide/getting-started.md)
* [Direct methods and options](docs/guide/direct-and-options.md)
* [Tutorial and embedding examples](examples/README.md)

## Further reading

### Using Fibers

* [Programming guide](docs/guide/getting-started.md)
* [Direct methods and options](docs/guide/direct-and-options.md)
* [Fibers for Roblox](docs/guide/roblox.md)
* [Gameplay examples](examples/gameplay/README.md)
* [Pipes, files, sockets and processes](docs/guide/io.md)
* [Non-blocking DNS](docs/guide/dns.md)
* [Happy Eyeballs v2](docs/guide/happy-eyeballs.md)
* [Tutorial and embedding examples](examples/README.md)
* [Facility recipes](examples/recipes/README.md)

### Semantics and lifetimes

* [Option algebra](docs/advanced/option-algebra.md)
* [Lifetimes: custody, Grants and Closure](docs/advanced/lifetimes-and-custody.md)
* [Flows, streams and the host reactor](docs/advanced/flows-and-streams.md)
* [Embedding and host integration](docs/advanced/embedding.md)
* [Port architectures: Rust, Embassy, WASM and Kotlin](docs/advanced/ports.md)

### Implementation and comparison

* [Comparison with related systems](docs/design/comparison.md)
* [Kernel design](docs/design/kernel.md)
* [Execution frontiers](docs/design/execution-frontiers.md)
* [Packages, profiles and embedding](docs/design/packages-and-embedding.md)

### Extending and contributing

* [Facility authoring](docs/advanced/facility-authoring.md)
* [Trusted executable resource leaves](docs/contributing/trusted-resource-leaves.md)
* [Repository layout](docs/contributing/repository-layout.md)
* [Lua compatibility](docs/contributing/compatibility.md)
* [Test profiles](docs/contributing/testing.md)
