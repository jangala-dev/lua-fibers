# Port architectures

This note records the intended architecture for ports of the Fibers semantics.
It is a design direction rather than part of the Lua version 1 API contract.
The normative portable material is the option algebra, proof outcomes, commit
protocol, callback phases and Lifetime laws.

## Shared semantic centre

Every port should retain one semantic core:

```text
option language
  always / primitive / choice / and_then / product / or_else / consequence
        |
proof search
  Hit / Retry / Unknown
        |
serial validation and commit
        |
Lifetime custody, Scope and Task views, and Closure
```

Host integration supplies clocks, wake-up, I/O completion and external facts. It
does not define transaction meaning. Search order, storage representation and
outer executor integration may vary provided they preserve the same admissible
worlds and the same distinction between Retry and Unknown.

The three callback phases apply unchanged in every language:

1. speculative search callbacks are pure and replayable;
2. effect preparation is pure, while effect discharge is post-commit;
3. participant continuation runs after commitment.

Capacity exhaustion in a bounded implementation is Unknown, never Retry. An
implementation limit must not prove that a preferred option is absent.

## Luau and Roblox profile

The generated Luau target is the first language-port experiment and should
remain source-compatible with the Lua semantic centre. Roblox adds an embedded
host profile rather than a different concurrency model. The source tree now
contains the first experimental slice: a bounded manual application driver,
event- and phase-scheduling policies, queued signal delivery, Lifetimes for
subscriptions and bounded `BindToClose` Closure.

```text
Roblox task scheduler or Actor VM
└── one Fibers runtime
    ├── proof and commit engine
    ├── lightweight internal Luau fibres
    ├── Lifetime forest, capability views and Closure
    └── RBXScriptSignal and engine-resource adapters
```

Roblox owns the scheduler and frame lifecycle. The canonical boundary is a
non-blocking `Application:advance` call supplied with an absolute host time
horizon and bounded proof quantum. Fibers owns transactional admission, child
lifetimes, cancellation and Closure inside that turn. Reaching the host
horizon retains exact progress and is not Retry.

Ordinary engine callbacks publish queued external facts and request a later turn;
they do not run the solver or arbitrary participant continuation directly.
`Roblox.attach` supplies event-driven scheduling with one deferred wake and one
earliest-deadline timer, or scheduling at a selected RunService phase. Manual
engine loops may call `advance` themselves.

The implemented and prospective layers are:

```text
Application:advance     implemented: bounded manual host horizon
Event scheduling        implemented: coalesced defer plus earliest deadline
RunService phases       implemented: selected bounded phase turns
RBXScriptSignal         implemented: queued, latest or pulse subscription
BindToClose             implemented: root shutdown and bounded Closure
Players/characters      next: player-session and character helpers
RemoteEvent             future: message Streams and request Lifetimes under custody
DataStore/HTTP          future: host completion plus explicit Closure
Instance lifetime       future: custody and destruction observation
```

Parallel Luau Actors should initially contain separate Fibers worlds. Explicit
Actor messages cross the boundary as host events. A single transaction spanning
several Actors would require a distributed validation and commit protocol and is
not part of the initial profile.

The portable gameplay examples should serve as shared Lua, Luau, Roblox and
browser demonstrations. See `docs/guide/roblox.md`.

## Rust family

The Rust implementation should be layered rather than forced into one storage
or host profile.

```text
fibers-model       portable semantic and conformance types
fibers-core        proof, commit and Lifetime logic
fibers-static      no_std/no_alloc bounded storage
fibers-alloc       no_std + alloc dynamic storage
fibers-embassy     MCU host adapters and root driver
fibers-web         browser/WASM host adapters
fibers-wasi        WASI component and server adapters
fibers-std         desktop and server host facilities
```

The core should be a pollable state machine. It should not require Tokio,
Embassy or a browser executor and should not create one host task per Fibers
fibre.

### Internal Rust fibres

A Fibers fibre is an ordinary Rust async function or async block stored and
polled by the Fibers runtime:

```rust
scope.spawn(async move {
    let request = requests.get().await?;
    handle(request).await
}).await?;
```

Calling an async function creates an inert Future. Transactional `spawn_op`
should retain an inert future factory and admit its frame only when the complete
candidate commits. A losing spawn occurrence must never poll the future.

After commitment the runtime:

1. obtains bounded or allocated frame storage;
2. constructs and pins the future in that storage;
3. records Lifetime parentage and the Scope capability;
4. places the fibre identifier on the internal ready queue;
5. polls it during a later or current runtime turn.

This is an inversion of the usual embedded arrangement. Embassy or the browser
drives one outer Fibers runtime future; Fibers owns the inner task graph.

```text
host executor task or root Promise
└── Fibers runtime Future
    ├── proof and commit engine
    ├── ready-fibre queue
    ├── Lifetime forest and Scope views
    └── lightweight internal Future frames
```

The host executor remains responsible for waking and polling the root future.
Fibers is responsible for transactional admission, cancellation, scheduling and
Closure of its internal fibres.

### Waking

Each internal fibre needs a small erased Waker containing at least:

```text
runtime reference
fibre slot index
generation
```

A wake validates the generation, marks the fibre ready and wakes the outer root
future. The generation prevents a late timer, interrupt or host callback from
waking a different future which later reused the same slot.

Fibers-native resources can normally enqueue a FibreId directly. An arbitrary
host Future receives the same per-fibre Waker when Fibers polls it.

### Work budgeting

One outer poll must perform bounded work before yielding to its host executor.
Separate limits should cover:

```text
internal fibre polls per turn
proof steps per turn
commits per turn
Closure work per turn
```

A turn limit yields and retains work. A proof or storage capacity limit returns
Unknown with a capacity reason. These outcomes are not interchangeable.

## Embassy and MCU profile

Fibers applications should be direct users of Embassy and MCU futures. Device
drivers do not need to be wrapped in one Embassy task per logical Fibers fibre.
An internal fibre may await a normal Embassy driver future sequentially:

```rust
async fn sensor_fibre(mut sensor: Sensor<'static>, readings: Sender<Reading>) {
    loop {
        let reading = sensor.read().await;
        readings.put(reading).await;
    }
}
```

When a host operation must participate in a Fibers transaction, its adapter
provides an option rather than an ordinary one-shot await:

```rust
perform(choice((
    radio.receive_op(),
    shutdown.next_op(),
    deadline.elapsed_op(),
))).await?;
```

The distinction is semantic, not a separate driver stack:

```text
ordinary Embassy Future     sequential wait inside one fibre
Fibers option adapter       participant in choice, and_then, products or fallback
```

### Strict no_std/no_alloc storage

Removing Embassy tasks does not remove async frame storage. Every live async
function has a compiler-generated state-machine frame which must remain pinned.
A strict no-allocation profile therefore needs declared capacity.

Possible storage forms are:

* generated typed pools per async function;
* fixed-capacity heterogeneous slabs with several size classes;
* Lifetime-local frame arenas;
* caller-supplied static arenas.

The profile should expose maxima for at least:

```text
live fibres and frame bytes
option nodes or typed composition depth
participants and pending performs
search frames and trail entries
ledger locations and writes
effects and custody records
retained proof sessions
```

A `#[fiber(pool_size = N)]`-style macro may generate a poll/drop descriptor and
static frame pool for a concrete async function. A more dynamic arena may use an
erased vtable, slot generation and fixed alignment classes.

Fibre-slot availability may itself be a managed transactional resource. This
allows admission to compose lawfully with fallback or overload policy. Lack of
capacity must be represented explicitly; it must not become an accidental panic
or an unsound proof of general absence.

### Cancellation

Cancellation is cooperative. It is observed when an internal future yields to
Fibers or reaches a Fibers transaction boundary. A CPU loop or blocking foreign
call can still delay the runtime. The Lifetime retains custody until the future
finishes and Closure completes or fails explicitly.

## Browser WASM profile

The browser profile should use one root Rust Future driven by the JavaScript
event loop. Internal Fibers fibres should not each become a JavaScript Promise or
`spawn_local` task.

```text
JavaScript event loop
└── root Fibers Future
    ├── internal Rust fibres
    ├── proof and commit engine
    ├── browser event feeds
    ├── Lifetimes and Closure
    └── host resource adapters
```

A JavaScript Promise completion or DOM event callback should:

1. update an authorised external feed or host primitive;
2. mark the affected Fibers participant ready;
3. wake the root future.

The browser and MCU profiles can therefore share the inner scheduler and differ
mainly at the host boundary:

```text
Embassy interrupt or driver wake  -> wake root Fibers future
Promise or EventTarget delivery   -> wake root Fibers future
```

### Useful browser adapters

```text
Promise                 one-shot external completion
EventTarget             event stream, queue or pulse
AbortSignal             cancellation feed
setTimeout              deadline option
fetch                    request, response and body lifetime
WebSocket               duplex Stream held in custody
WebRTC data channel      stateful duplex resource held in custody
IndexedDB request        external completion and transaction boundary
Worker message           channel-like external feed
Transferable object      custody movement between runtimes
page lifecycle event     scope cancellation or supervision input
```

Host APIs are generally not retractable. Their adapters must state which phase
contains the irreversible action. Option construction and preparation remain
pure; fetch initiation, DOM mutation, object transfer and similar actions belong
in effect discharge or participant continuation after commitment.

A Web Worker is a natural home for a long-lived Fibers runtime coordinating
connections, local storage, retries and several page clients. The first browser
profile need not use WebAssembly threads. Separate workers should initially own
separate Fibers worlds and communicate through explicit channels; distributing
one transaction across workers would require a different commit protocol.

### Practical value

The first strong WASM use may be the hosted twin of an MCU application:

```text
MCU                             browser
real drivers                    simulated or remote devices
Embassy time and interrupts     virtual time and browser events
fixed-capacity runtime          allocated or bounded runtime
same protocol and lifetime logic
```

This supports deterministic simulation, failure injection, browser-based device
tools, protocol demonstrations and differential testing of application logic.

## WASI and hosted Rust

An allocated `no_std + alloc` or `std` implementation should retain dynamic
option graphs, flexible participant sets and rich diagnostics. It is the most
suitable first Rust port because it can be compared closely with the Lua
production and reference evaluators before fixed-capacity representation choices
are frozen.

WASI and server hosts can map asynchronous functions, streams, sockets and HTTP
to Fibers primitives. Fibers remains useful where a service needs transactional
admission, certified overload fallback, graceful shutdown, streaming custody or
cleanup which may itself fail. Simple stateless request handling does not require
the full algebra.

## Kotlin profile

Kotlin coroutines should provide suspension, dispatch and ordinary parent-child
job integration. They should not replace the Fibers evaluator.

```text
Kotlin CoroutineDispatcher / CoroutineScope
└── Fibers runtime
    ├── option evaluator and ledger
    ├── Lifetimes and Closure
    └── internal Fibers continuations
```

`CoroutineScope`, `Job` and `SupervisorJob` map well to ordinary structured
lifetime policies. Kotlin channels and `select` map to simple waits and races.
They do not by themselves provide transactional and_then, proof-directed
or_else, all versus tensor, provisional rollback or custody Closure.

A Kotlin port should therefore:

* use suspend functions as the direct sequential surface;
* use inert Option values for Fibers composition;
* host the proof and commit kernel separately from coroutine selection;
* map committed child admission to a coroutine launch only after commit;
* retain Lifetime and Closure outcomes as structured values rather than hiding
  them entirely in CancellationException or finally blocks.

Kotlin is likely to use allocated graphs and continuations. Its principal value
would be a common concurrency model across Android, JVM services and MCU-facing
protocol code, rather than no-allocation operation.

## Port order

A prudent sequence is:

1. freeze the language-independent option, effect and Lifetime contracts;
2. build a portable conformance corpus from the Lua production and reference
   evaluators;
3. package the strict Luau target and implement the single-world Roblox host;
4. validate scenes, player sessions and substantial game mechanics in Studio;
5. implement Rust with alloc/std and differential tests;
6. add browser and WASI hosts around the same Rust core;
7. design fixed-capacity storage and the Embassy root driver;
8. add the strict no_std/no_alloc profile;
9. implement Kotlin above its coroutine host.

The portable conformance corpus should compare possible committed worlds,
resource writes, participant sets, effects, defeat obligations, Retry facts and
Unknown reasons. Matching returned values alone is insufficient.

## External references

These projects describe the host mechanisms assumed by this note:

* Roblox task scheduler: https://create.roblox.com/docs/reference/engine/libraries/task
* Roblox Parallel Luau and Actors: https://create.roblox.com/docs/scripting/multithreading
* Embassy executor and futures: https://docs.embassy.dev/
* Rust and JavaScript future bridging:
  https://wasm-bindgen.github.io/wasm-bindgen/reference/js-promises-and-rust-futures.html
* Kotlin coroutine scopes and jobs: https://kotlinlang.org/docs/coroutines-basics.html
