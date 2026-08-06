# Fibers

Transactional structured concurrency for Lua and Luau.

Fibers lets a program compose a complete concurrent action before any part of it commits.

An Option may coordinate several participants, communicate values, change managed state, admit new tasks and move responsibility. When selected, it commits as one complete action; otherwise none of its provisional changes commit.

Every continuing consequence of the committed action belongs to a Lifetime until it closes.

> **What may happen is an Option. What remains is a Lifetime.**

Write local behaviour as sequential fibers. Compose complete actions as Options. Account for continuing consequences through Lifetimes.

Fibers is a process-local concurrency library for standalone and embedded programs. The same small vocabulary scales from simple scripts to long-lived systems.

## Begin with sequential fiber code

A fiber runs an ordinary Lua function:

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

Direct methods such as `get` and `put` keep ordinary sequential code concise:

```lua
local command = commands:get()
```

This is exactly:

```lua
local command = fibers.perform(commands:get_op())
```

Fibers uses cooperative fibers and event-driven scheduling beneath this sequential model. It does not require actors, reactive pipelines or another application-wide structure.

## Actions are Options

Fibers facilities describe their actions as Options.

Methods ending in `_op` return those descriptions without performing them:

```lua
local receive = commands:get_op()
```

Constructing this Option does not receive anything. It describes a possible receive action.

`perform` submits an Option for selection and commitment:

```lua
local command = fibers.perform(receive)
```

Options can be combined before they are performed:

```lua
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')

local commands = channel.new()
local shutdown = channel.new()

local next_event = Op.choice(
  commands:get_op(),
  shutdown:get_op(),
  Sleep.sleep_op(30):map(function()
    return nil, 'idle deadline reached'
  end)
)

local value, err = fibers.perform(next_event)
```

Constructing `next_event` does not receive a command, receive a shutdown request or begin sleeping. It describes the actions which may form the next committed result.

Direct methods add no concurrency semantics. They simply perform the corresponding Option immediately. The Option form exposes the same action for composition.

## The unit of composition is a complete action

An Option is not limited to one channel operation, state access or task.

Consider a service which should consume a request only when it can also admit a task responsible for handling it:

```lua
local Op = require('fibers.op')
local channel = require('fibers.channel')

local requests = channel.new()

local function accept_request_op(scope)
  return requests:get_op():and_then(
    Op.guard(function(request)
      return scope:spawn_op(function()
        return handle_request(request)
      end)
    end)
  )
end
```

This describes one coherent concurrent action.

If it cannot commit:

* the request is not consumed;
* the task body does not start;
* no responsibility is created.

If it commits:

* the request is received;
* the handler task is admitted;
* the task is already accountable to the scope.

The task is not started speculatively and then cancelled if another alternative wins. A request therefore cannot disappear into a service which is no longer able to own its handler.

The complete action can itself participate in further composition:

```lua
local task, err = fibers.perform(
  accept_request_op(scope)
    :or_else(Op.always(nil, 'not accepting now'))
)
```

`or_else` asks whether the complete admission action can happen now. It does not merely inspect the request channel or a local readiness flag.

This is the central source of Fibers’ expressive power:

> Every facility which exposes an Option joins the same algebra.

A channel receive, state transition, timer, task admission, process result or custody movement can be:

* selected;
* sequenced transactionally;
* preferred through `or_else`;
* combined independently through `each`;
* combined interactively through `together`;
* labelled and observed.

A new facility does not introduce another concurrency model. It adds another kind of action to every existing form of composition.

## The Option algebra

| Expression          | Read it as                                        |
| ------------------- | ------------------------------------------------- |
| `Op.always(value)`  | this result is already available                  |
| `Op.never()`        | this Option cannot succeed                        |
| `Op.choice(a, b)`   | either coherent result is acceptable              |
| `a:and_then(b)`     | satisfy `a`, then `b`, in one transaction         |
| `a:or_else(b)`      | use `a` if it can happen now; otherwise use `b`   |
| `Op.each(a, b)`     | satisfy both, with each standing on its own       |
| `Op.together(a, b)` | satisfy both, allowing compatible sibling support |
| `a:map(f)`          | transform provisional results                     |
| `a:wrap(f)`         | run participant-local code after commitment       |
| `Op.guard(f)`       | construct the next Option from provisional values |

### `choice`: either result is acceptable

```lua
local outcome = fibers.perform(Op.choice(
  voice_lines:get_op(),
  Sleep.sleep_op(1):map(function()
    return '[continue with subtitles]'
  end)
))
```

Source order does not express priority.

Each branch may be a complete transactional protocol rather than one primitive event. Losing alternatives make no committed changes.

### `and_then`: one transactional sequence

```lua
local admit_party = arena_places:take_op(#party.players)
  :and_then(match_lobby:put_op(party))
```

Capacity is consumed only if the party can also be admitted. Earlier actions remain provisional until the complete sequence succeeds.

When the next Option depends on provisional values, use `Op.guard`:

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

### `or_else`: act now or fall back

```lua
local action = attack_op(agent, target)
  :or_else(take_cover_op(agent))
  :or_else(return_to_patrol_op(agent))
```

This means:

1. attack if an attack can happen now;
2. otherwise take cover if that can happen now;
3. otherwise return to patrol.

“Can happen now” means that a coherent transaction can commit without waiting for a future change.

That transaction may involve another current participant, alternative communication partners, provisional state changes, task admission or several mutually compatible actions.

Fibers does not reduce “now” to a local readiness flag, default branch or polling interval.

A timeout is a different statement:

```lua
local result = fibers.perform(Op.choice(
  request:reply_op(),
  Sleep.sleep_op(5):map(function()
    return nil, 'deadline reached'
  end)
))
```

`or_else` concerns present possibility. A timer concerns the passage of time.

### `each` and `together`

Both operators require every lane to succeed.

With `each`, every lane must be supportable without positive supply from its siblings:

```lua
local reservations = Op.each({
  camera_channels:take_op(1),
  animation_channels:take_op(1),
})
```

With `together`, compatible siblings may deliberately make one another possible:

```lua
local handoff = Op.together({
  cue_bus:inlet():write_op('GO'),
  cue_bus:outlet():read_some_op(2),
})
```

Here the write is intended to supply the read. Both commit as one coherent result.

| Question                                  | Use        |
| ----------------------------------------- | ---------- |
| Must every lane stand on its own?         | `each`     |
| May compatible lanes support one another? | `together` |

The complete practical account is in [Options](docs/guide/options.md).

## When callbacks run

Fibers distinguishes code which helps describe a possible world from code which runs after that world commits.

* `map` transforms provisional results.
* `guard` constructs a continuation from provisional values.
* `wrap` runs participant-local code after commitment.

Callbacks used by `map` and `guard` may be revisited while alternatives are considered. They must be deterministic, non-yielding and free of externally visible or irreversible side effects.

A `wrap` callback may update ordinary application objects, log, spawn work or perform further Options. It cannot alter the transaction which has already committed.

> Use `map` and `guard` to describe possible results. Use `wrap` for ordinary application work after selection.

Only state represented through Fibers facilities participates in rollback and commitment. Ordinary Lua tables and globals are not made transactional.

## Options and Lifetimes

Two concepts organise Fibers:

1. **Options** describe possible actions and the coherent worlds they may form.
2. **Lifetimes** account for what committed worlds leave alive.

An Option may describe anything from an immediate value to a complete multi-party action:

```lua
local command = fibers.perform(commands:get_op())
```

`perform` is a possible suspension point, not an instruction to suspend. If the Option can commit immediately, the fiber continues immediately.

A Lifetime records continuing consequences and who remains responsible for them:

```lua
fibers.run(function(scope)
  local task = scope:spawn(function()
    return load_map('Moon Garden')
  end)

  return task:await()
end)
```

Child work remains accountable to a parent boundary.

Lifetime operations are Options too. Task admission, responsibility transfer,
authority, cancellation and completion may share a commit boundary with
communication and managed state:

```lua
local accepted = requests:get_op():and_then(
  Op.guard(function(request)
    return scope:spawn_op(function()
      return handle_request(request)
    end)
  end)
)
```

Here the request is consumed only if the handler Task can also be admitted under
responsibility. A similar transaction may move custody, issue a Grant or request
cancellation as part of the complete action.

Fibers applies the same principle to tasks, scopes, streams, processes and retained host resources rather than giving each a separate cleanup convention.

## Accountable lifetimes

The root scope follows nursery semantics:

* failed child work fails the boundary;
* remaining siblings are asked to close;
* the boundary does not return while retained responsibility remains unresolved.

Supervisor scopes can apply another explicit child-failure policy.

The public views answer different questions over one Lifetime:

| View | Principal question |
|---|---|
| `Scope` | what may be admitted, owned, moved or closed here? |
| `Task` | how did the body finish, and has the complete consequence resolved? |
| `Grant` | who may perform which operation without becoming the custodian? |
| `Closure.Failure` | what remains unresolved, and who may retry or force it? |

`body_result_op()` observes the executing function. `outcome_op()` observes the
complete Lifetime after descendants and Closure. This distinction lets a
supervisor react promptly to failure while still deciding whether replacement
must wait for complete retirement.

### Custody

Custody answers:

> Who is responsible for ensuring that this continuing consequence eventually closes?

Every live Lifetime has one custodial parent. Responsibility is unique.

Retaining a Lua reference does not create custody. Custody may move as part of a committed action without becoming absent or ambiguous.

Movement may be coupled transactionally to the state change, message or
acknowledgement which justifies the hand-off. Negotiated `offer_op` and
`accept_op` let the receiver participate in the same committed transfer.

### Grants

Authority is represented separately through Grants.

Permission to use, cancel or inspect something does not create a second owner. Rights and transferability are explicit; authority is not copied onwards through implicit sub-Grants.

Grant issuance and delivery may be one transaction, and `can_op` can be composed
with the protected action so authority cannot change between a separate check
and use.

This separates:

* who may act;
* who must eventually account for the result.

### Closure

Closure accounts for a Lifetime and everything beneath it.

A parent does not report successful Closure while descendants remain unresolved. Successful partial progress is retained. If Closure cannot finish, the unresolved responsibility remains explicit and may be retried or forced through one retained recovery capability.

Admission, movement and Grant issuance are provisional managed changes. Closure
is intentionally different: selection of which Closure begins is transactional,
but external shutdown after commitment cannot generally be rolled back.

Tasks, streams, processes and retained host resources therefore share one rule:

> A boundary has not finished while something beneath it remains unaccounted for.

Cancellation is cooperative. Fibers cannot pre-empt an infinite CPU loop, a blocking foreign call or code which never reaches a recognised suspension point.

See:

* [Lifetimes](docs/guide/lifetimes.md)
* [Custody, Grants and Closure](docs/advanced/custody-grants-and-closure.md)

## Execution contracts and observability

### Uninterrupted reductions

Fibers supports actor-like coordinators without requiring the whole program to use the Actor model.

A coordinator may:

1. wait for one event;
2. reduce it to a new quiescent state;
3. return to its outer event Option.

```lua
local coordinator = fibers.spawn(function()
  while true do
    local event = fibers.perform(next_event_op(state))

    fibers.without_suspension(function()
      reduce_event(state, event)
    end)
  end
end)
```

`without_suspension` asserts that the function begins and finishes without the current fiber relinquishing execution.

It permits performed Options which commit without actual suspension.

It fails before:

* the current fiber is parked;
* another participant is resumed first;
* control must return to the embedding host.

It is an execution assertion, not:

* a transaction;
* a lock;
* rollback for ordinary Lua mutation;
* a duration limit;
* protection against a foreign call which blocks without returning to Fibers.

### Labels

Fibers assigns stable internal identities automatically.

Long-lived tasks, scopes, resources and important Options may also carry optional human-readable labels:

```lua
local commands = channel.new(16)
  :label('service-commands')

local worker = fibers.spawn(run_worker)
  :label('configuration-watcher')

local receive = commands:get_op()
  :label('receive-command')
```

Labels are optional, non-unique and semantically inert.

They affect diagnostics and instrumentation, not:

* matching;
* scheduling;
* identity;
* custody;
* authority;
* commitment.

Because scheduling is cooperative, the uninterrupted fiber turn is a natural unit for profiling: it measures how long one fiber retains execution before returning control.

Labels provide the application vocabulary needed to associate such measurements with the relevant task, Option and resource rather than only internal identifiers.

See [Execution and observability](docs/advanced/execution-and-observability.md).

## One vocabulary across the library

Fibers includes host-neutral and host-backed facilities built on the same Option and Lifetime semantics:

* channels, notifications and mailboxes;
* transactional state and capacity;
* byte flows and streams;
* timers;
* files, processes and sockets;
* embedded and Roblox hosts.

Their direct methods perform the corresponding Options. The Option form exposes an action for composition; the direct form performs it immediately.

Host readiness remains beneath the application model. I/O progress, process completion and resource ownership appear as possible actions and accountable consequences rather than unrelated callbacks and cleanup conventions.

Fibers can support:

* CSP-style channel programs;
* actor-like coordinators;
* backpressured streaming;
* supervised services;
* transactional resource protocols;
* embedded host-loop integrations.

These are patterns built from Fibers, not separate frameworks within it.

See:

* [Resources](docs/guide/resources.md)
* [Files, pipes, processes and sockets](docs/guide/io.md)
* [Embedding](docs/guide/embedding.md)
* [Fibers for Roblox](docs/guide/roblox.md)

## Standalone and embedded use

For a standalone application, `fibers.run` creates and drives one independent Fibers instance until the root scope finishes:

```lua
fibers.run(function(scope)
  scope:spawn(run_server)
  scope:spawn(run_monitor)
end)
```

An existing host can instead advance Fibers incrementally.

This allows Fibers to fit inside:

* a game frame;
* a firmware control cycle;
* a plugin callback;
* an existing C, C++ or Rust event loop;
* an engine scheduling phase.

Fibers does not require process-global scheduler ownership.

See [Embedding](docs/guide/embedding.md).

## Relationship to related systems

Fibers brings together ideas which have usually appeared in separate systems.

| Tradition                                  | Relationship                                                                                                                        |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| **Concurrent ML and Transactional Events** | Options are first-class descriptions of synchronisation, extended to managed state, task admission and movement of responsibility   |
| **Transactional state systems**            | provisional changes compose and commit together, but the transaction is a complete concurrent action rather than only memory access |
| **Structured concurrency and supervision** | continuing work belongs to explicit boundaries, extended through custody and Closure to resources as well as tasks                  |

Fibers’ clearest precedents on the Option side are Concurrent ML and Transactional Events; on the Lifetime side they are structured concurrency and supervision.

Its distinction is the integration of those ideas:

> Communication, managed state, participant actions, task admission and responsibility movement may share one commit boundary. Every continuing consequence enters one Lifetime system.

At the execution level, Fibers uses cooperative Lua fibers and event-driven host integration. These are how programs run, not a separate application model.

Fibers is process-local and in memory. It does not provide durable workflows, distributed transactions or CPU parallelism.

A fuller comparison is in [Related systems](docs/design/comparison.md).

## Intended uses

Fibers is intended for programs whose concurrent behaviour should remain readable as it becomes more exact.

Examples include:

* firmware and controllers;
* robotics and autonomy;
* field systems;
* desktop and server applications;
* games;
* embedded plugin hosts;
* device orchestration.

Fibers is particularly suited to systems where several questions must be answered together:

* What can happen now?
* Which complete action should commit?
* What continuing work does it create?
* Who is responsible for that work?
* When has it genuinely finished?

Fibers coordinates work within one cooperative process domain.

It is not:

* a durable database;
* a distributed transaction system;
* a source of CPU parallelism;
* a substitute for process or hardware fault containment;
* a means of forcibly interrupting non-cooperative foreign code.

## Documentation

* [Getting started](docs/guide/getting-started.md)
* [Options](docs/guide/options.md)
* [Lifetimes](docs/guide/lifetimes.md)
* [Resources](docs/guide/resources.md)
* [I/O](docs/guide/io.md)
* [Embedding](docs/guide/embedding.md)
* [Fibers for Roblox](docs/guide/roblox.md)
* [API reference](docs/api-reference.md)
* [Advanced Option semantics](docs/advanced/option-algebra.md)
* [Execution and observability](docs/advanced/execution-and-observability.md)
* [Extending Fibers](docs/advanced/extending.md)
* [Implementation design](docs/design/kernel.md)
* [Related systems](docs/design/comparison.md)
* [Contributing](docs/contributing/contributing.md)
* [Runnable examples](examples/README.md)

## Project status

Production source uses the Lua 5.1 grammar. Development covers:

* Lua 5.1–5.5;
* LuaJIT 2.1;
* Luau.

Host facilities depend on the selected environment.

See:

* [Lua compatibility](docs/contributing/compatibility.md)
* [Packages and ports](docs/design/packages-and-ports.md)

## Getting started from a checkout

```sh
make test
make examples
```

Run the opening example with an available Lua interpreter:

```sh
lua5.4 examples/tutorial/00_getting_started.lua
```

Until the first packaged release, add `src` to the Lua module path or vendor `src/fibers` with the application.
