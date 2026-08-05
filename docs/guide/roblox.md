# Fibers for Roblox: from one scene to a whole game

Fibers is intended to let ambitious game logic read like the mechanic it
implements:

```text
play the entrance
or skip it
then return the camera
cancel everything if the player leaves
```

The difficult parts—provisional work, cancellation, child lifetimes, committed
side effects and cleanup—belong beneath that sentence rather than being spread
through event connections and delayed callbacks.

This guide is a step-by-step introduction for the experimental Roblox adapter
now included in the source tree. The generated Luau target contains
`fibers.roblox.host`, `fibers.roblox` and the signal-subscription adapter with Lifetime custody.
Packaging for Wally and Roblox model distribution remains future release work,
but the host boundary and its portable fake-engine tests are implemented.

There are two companion collections:

- [`examples/gameplay/`](../../examples/gameplay/) contains portable mechanics
  which run under ordinary Lua and can be shared with browser demonstrations;
- [`examples/roblox/`](../../examples/roblox/) contains Studio-facing LocalScript
  and server Script examples using real Roblox services and signals.

## How Roblox drives Fibers

Roblox owns the scheduler, frame lifecycle and resumption points. Fibers is an
embedded subsystem rather than a second engine loop:

```text
Roblox scheduler or game loop
    → supplies one bounded execution horizon
    → Fibers advances until Closure, quiescence or turn exhaustion
    → Fibers returns its interests and earliest deadline
    → Roblox schedules another advance only when required
```

The canonical interface is `prepare` plus `advance`. Manual driving needs only
a monotonic clock and the callback queue; it does not require `task`,
`RunService` or a `BindableEvent`. The following example places that boundary
inside an existing Heartbeat loop; this is a manual phase-driven embedding, not
a requirement to poll Fibers every frame:

```luau
local app = Roblox.prepare(function(root)
    -- the root Fibers programme
end, {
    name = "game-client",
    max_steps_per_turn = 128,
    max_work_per_step = 512,
})

local driver

driver = RunService.Heartbeat:Connect(function()
    local status = app:advance({
        horizon = os.clock() + 0.001,
    })

    if status.state == "settled" then
        driver:Disconnect()
        local result = app:result()
        app:close()
        if not result.ok then
            warn(result)
        end
    end
end)
```

`advance` never waits for Roblox. Reaching its horizon or deterministic turn
budget retains the exact unfinished fibre and proof state for a later call. It
does not establish `Retry` and cannot admit an `or_else` fallback.

Most applications can place a scheduling policy above this boundary:

```luau
local app = Roblox.attach(rootProgramme, {
    scheduling = "event", -- the default
})
```

Event scheduling uses one coalesced `task.defer` after external delivery or
retained immediate work, and one `task.delay` for the earliest Fibers deadline.
It does not poll every frame.

Frame-sensitive systems may instead select a phase:

```luau
local app = Roblox.attach(rootProgramme, {
    scheduling = "phase",
    phase = RunService.Heartbeat,
    max_seconds_per_turn = 0.001,
})
```

Ordinary Roblox signal callbacks still only queue facts. The chosen phase is the
host scheduling boundary; Fibers advances afterwards under the declared budget.
`Roblox.run` and `Roblox.try_run` are convenience wrappers over `attach` for
scripts which want to yield until the root settles. They do not replace the
host-controlled scheduling boundary.

See [`examples/roblox/00_manual_horizon.client.luau`](../../examples/roblox/00_manual_horizon.client.luau),
[`examples/roblox/01_button_choice.client.luau`](../../examples/roblox/01_button_choice.client.luau)
and [`examples/roblox/06_phase_attach.client.luau`](../../examples/roblox/06_phase_attach.client.luau).

## 1. Begin with ordinary sequential scene code

Do not begin with the option algebra. Begin with the scene as a readable
sequence:

```luau
local FibersPackage = Packages.Fibers
local fibers = require(FibersPackage)
local Sleep = require(FibersPackage.sleep)
local Roblox = require(FibersPackage.roblox)

Roblox.run(function(scope)
    scope:spawn(function()
        playCameraTrack("ObservatoryEntrance")
    end):label("camera-track")

    showDialogue("The stars have been waiting for you.")
    Sleep.sleep(1.5)
    openMoonGate()
end, {
    name = "observatory-entrance",
})
```

`Roblox.run` is used here only to remove driver boilerplate: internally it
creates an event-attached application and yields this script while Roblox
continues to own scheduling. Larger systems will usually retain the
`Application` returned by `attach` or drive `prepare` manually.

A fibre is still an ordinary Luau function. Direct methods suspend where the
scene naturally waits. The scope accounts for every child before it returns.

This is the first promise Fibers should make to a gameplay programmer:

> straightforward mechanics remain straightforward code.

## 2. Ask for an option only when composition becomes useful

A direct operation performs now:

```luau
local cue = directorCues:get()
```

Its `_op` twin describes the same action without performing it:

```luau
local receiveCue = directorCues:get_op()
```

The option form earns its place when the action joins a larger decision:

```luau
local selected, detail = fibers.perform(Op.named_choice({
    completed = cinematicFinished:get_op(),
    skipped = skipRequested:get_op(),
    player_left = playerLeft:get_op(),
}))
```

Read this as written: the scene may complete, be skipped, or lose its player.
There is no separate cancellation protocol hidden behind each branch.

## 3. Give a cutscene one lifetime

A polished cutscene commonly owns:

- camera control;
- animation tracks;
- dialogue and subtitles;
- sound and music cues;
- temporary input restrictions;
- NPC blocking;
- props and visual effects;
- skip handling.

Put that work under one scene scope:

```luau
local outcome = fibers.scope({ name = "opening-cinematic" }, function(scene)
    local camera = scene:spawn(playOpeningCamera):label("camera")
    local dialogue = scene:spawn(playOpeningDialogue):label("dialogue")
    local blocking = scene:spawn(runNpcBlocking):label("npc-blocking")

    local selected, reason = fibers.perform(Op.named_choice({
        completed = sceneFinished:get_op(),
        skipped = skipRequested:get_op(),
        player_left = playerLeft:get_op(),
    }))

    if selected ~= "completed" then
        camera:request_cancel(reason)
        dialogue:request_cancel(reason)
        blocking:request_cancel(reason)
    end

    return selected, reason
end)
```

The scene does not return while work under the scene Scope remains unaccounted for. A
skip is therefore an ordinary exit path, not a collection of emergency flags.

See [`00_skippable_cutscene.lua`](../../examples/gameplay/00_skippable_cutscene.lua).

## 4. Separate selection from post-commit presentation

Callbacks used by `map`, guards and transactional resource
transitions are speculative. Fibers may revisit them while looking for a
coherent world. They must be pure and non-yielding.

Use `wrap` for participant-local work which should run only after selection:

```luau
local outcome = fibers.perform(
    skipRequested:get_op()
        :map(function(reason)
            -- Pure: construct the selected value only.
            return { kind = "skipped", reason = reason }
        end)
        :wrap(function(result)
            -- Post-commit: ordinary game work is allowed here.
            playSkipWhoosh()
            hideSkipPrompt()
            return result
        end)
)
```

The three phases are normative:

1. **speculative construction** — pure, replayable and non-yielding;
2. **committed-world effects** — pure preparation followed by post-commit
   discharge;
3. **participant continuation** — `wrap`, where ordinary performing work may
   continue.

This distinction is what lets readable game logic remain transactionally true.

## 5. Make a player session a scope

A player session may own profile refresh, character observation, quest delivery,
replication state and temporary world objects. Those activities should not
outlive the player.

```luau
local function servePlayer(player: Player)
    return fibers.scope({ name = `player:{player.UserId}` }, function(session)
        session:spawn(function()
            refreshProfileLockUntilSessionEnds(player)
        end):label("profile-lock")

        session:spawn(function()
            followCharacterRespawns(player)
        end):label("character-lifetime")

        session:spawn(function()
            deliverQuestUpdates(player)
        end):label("quest-delivery")

        local reason = playerRemoving:get_for(player)
        sessionEnding:close(reason)
        return reason
    end)
end
```

The experimental adapter turns `Players.PlayerAdded`, `PlayerRemoving`,
character replacement and similar signals into event sources held in custody through
`Roblox.events`, `Roblox.latest` or `Roblox.pulse`. The underlying Roblox events
remain host facts; the session lifetime remains a Fibers concept.

See [`01_player_session.lua`](../../examples/gameplay/01_player_session.lua).

## 6. Admit a match transactionally

Check-then-act matchmaking code is vulnerable to partial admission:

```text
check capacity
reserve players
create match state
start match task
```

If any later step fails, application code must undo every earlier step.
Fibers can describe the complete admission as one world:

```luau
local function admitMatch_op(scope, party, arena)
    return arena.freePlaces:take_op(#party.players)
        :and_then(arena.rotation:expect_op("open"))
        :and_then(scope:spawn_op(function()
            return runMatch(party, arena)
        end, {
            label = `match:{party.id}`,
        }))
end
```

A fallback can be explicit:

```luau
local result = fibers.perform(
    admitMatch_op(scope, party, moonArena)
        :or_else(waitingRoom:admit_op(party))
)
```

The waiting room is not selected because admission happened to take too long.
It is selected only after the preferred match admission is presently refuted
under managed facts.

See [`02_atomic_match_admission.lua`](../../examples/gameplay/02_atomic_match_admission.lua).

## 7. Express AI as an intention ladder

Game AI often already uses natural-language preference:

```text
attack
or else take cover
or else search
or else return to patrol
```

Fibers can preserve that form:

```luau
local intention = attackPlayer_op(agent, target)
    :or_else(takeCover_op(agent))
    :or_else(searchLastKnownPosition_op(agent, target))
    :or_else(returnToPatrol_op(agent))

local action = fibers.perform(intention)
```

`or_else` is stronger than branch order. A lower intention becomes admissible
only after the preferred intention has a valid present refutation. Search
exhaustion is `Unknown`, not permission to behave differently.

That distinction can reduce oscillation and arbitrary timeout-driven behaviour.
It also makes the decision legible to tools: an inspector can show which
intention won and why the earlier tier was absent.

See [`03_ai_intention_ladder.lua`](../../examples/gameplay/03_ai_intention_ladder.lua).

## 8. Model exclusive control as custody

Games contain many temporary owners:

- a cinematic owns the camera;
- a vehicle owns a character seat;
- an ability owns an animation layer;
- a dialogue owns input focus;
- a match owns its arena;
- a quest owns temporary world objects.

A camera hand-off can change protocol state and custody together:

```luau
local releaseCamera = cameraProtocol:receive_op():and_then(
    Op.guard(function(message)
        if message ~= "RELEASE_CAMERA" then
            return Op.never()
        end

        return cameraMode:write_op("player")
            :and_then(cinematicScope:move_op(cameraHandle, gameplayScope))
            :and_then(cameraProtocol:send_op("CAMERA_READY"))
    end)
)
```

The receiving system cannot observe half a hand-off in which the mode changed
but custody did not move.

See [`04_camera_custody.lua`](../../examples/gameplay/04_camera_custody.lua).

## 9. Choose nursery or supervisor behaviour deliberately

Some child failures should end the mechanic immediately:

- the authoritative match simulation failed;
- the boss controller lost its state;
- the scene camera cannot continue.

Use the default fail-fast nursery Closure for these.

Other failures should be retained without destroying the main experience:

- one optional firework launcher failed;
- an ambient flock could not spawn;
- a cosmetic telemetry task stopped.

Use a collecting supervisor:

```luau
local eventResult = fibers.try_scope({
    name = "eclipse-festival",
    closure = Closure.supervisor({ child_failure = "collect" }),
}, function(event)
    event:spawn(runMoonrise):label("headline-moonrise")
    event:spawn(runFireworks):label("optional-fireworks")
    event:spawn(runCrowdAmbience):label("crowd-ambience")

    return festivalFinished:get()
end)
```

The report retains optional failures for Studio diagnostics and production
telemetry.

See [`05_live_event_supervision.lua`](../../examples/gameplay/05_live_event_supervision.lua).

## 10. Turn inventory and world changes into one mechanic

A mechanic such as “consume the silver key and open the Moon Gate” should not
lose the key if the gate cannot change state.

```luau
local unlockMoonGate = Op.each({
    inventory.silverKeys:take_op(1),
    moonGate.state:expect_op("locked"),
}):and_then(moonGate.state:write_op("open"))
```

The key and gate change commit together. If the complete world is absent, the
provisional key take is retracted.

See [`06_unlock_the_moon_gate.lua`](../../examples/gameplay/06_unlock_the_moon_gate.lua).

## 11. Use ordinary choice for timing windows

Not every decision requires proof-directed fallback. A combo input and the end
of its timing window are simply competing events:

```luau
local selected, detail = fibers.perform(Op.named_choice({
    input = followUpInput:get_op(),
    expired = Sleep.sleep_op(COMBO_WINDOW):map(function()
        return "return to neutral stance"
    end),
}))
```

Use `choice` when either outcome is permitted. Use `or_else` when a fallback is
permitted only after the preferred option is proved absent.

See [`07_combo_window.lua`](../../examples/gameplay/07_combo_window.lua).

## 12. Bridge Roblox signals without re-entering Fibers

The adapter exposes three deliberate buffering policies:

```luau
local clicks = Roblox.events(button.Activated, {
    name = "continue-button",
})

local health = Roblox.latest(humanoid.HealthChanged, {
    name = "latest-health",
})

local frames = Roblox.pulse(RunService.Heartbeat, {
    name = "heartbeat-pulse",
})
```

- `events` retains every firing in order;
- `latest` coalesces a burst and retains its newest arguments;
- `pulse` coalesces a burst and returns the newest logical generation.

Each subscription owns its `RBXScriptConnection`. It is disconnected when the
custodial Scope closes, or explicitly through `subscription:close()`.

```luau
local pressed = Roblox.events(skipButton.Activated, {
    name = "skip-button",
})

local reason = pressed:next()
```

An ordinary engine callback never invokes the proof engine directly. Even an
immediate signal which fires while a Fibers participant is running follows this
route:

```text
RBXScriptSignal callback
    → append or coalesce a queued host delivery
    → request one future application turn
    → Application:advance reaches the external-driver boundary
    → publish the managed fact
    → resume proof and participant work within the host horizon
```

Repeated callbacks coalesce their scheduling request, although `events` still
retains each payload. Event scheduling remains dormant while there is no external
fact, deadline or immediate Fibers work. Phase scheduling advances only at its
selected engine phase.

Use queued events for discrete facts such as button presses, RemoteEvent
messages and animation markers. Use `latest` for state-like observations where
intermediate values may be discarded. Use `pulse` for invalidation and frame
notifications where the number of coalesced firings is less important than the
fact that something changed.

Signal subscription is an immediate committed host action. Construct it in the
body of a running fibre or another post-commit path, not inside `guard`, `map`,
effect preparation or another callback which Fibers may replay. The
returned subscription is then an ordinary resource held in custody: `next_op()` is inert,
`close_op()` is transactional, and Scope Closure disconnects it.

The signal-mode example deliberately fires several observations before one
manual `advance`, making all three buffering contracts observable rather than
depending on frame timing.

See [`examples/roblox/01_button_choice.client.luau`](../../examples/roblox/01_button_choice.client.luau)
and [`examples/roblox/05_signal_modes.client.luau`](../../examples/roblox/05_signal_modes.client.luau).

## 13. Close the server at shutdown

`Roblox.bind_to_close(scope)` installs a monitor Lifetime and registers a
`DataModel:BindToClose()` callback:

```luau
Roblox.run(function(root)
    Roblox.bind_to_close(root, {
        deadline = 25,
        reason = "Roblox server closing",
        on_timeout = function(reason)
            warn("Fibers shutdown deadline reached", reason)
        end,
    })

    root:spawn(runWorldSimulation):label("world-simulation")
    fibers.perform(Op.never())
end, {
    name = "game-server",
})
```

The callback queues one shutdown fact and waits. The hidden Fibers monitor
requests root cancellation from inside the runtime, after which normal scope and
Lifetime Closure applies:

- root admission is sealed by the scope Closure;
- live child tasks observe cancellation at Fibers suspension points;
- signal subscriptions disconnect through their Lifetimes;
- player sessions, matches and host resources close before the runtime ends;
- failed Closure remains represented in the resulting scope report;
- Roblox's callback returns when Closure completes or the adapter deadline is
  reached.

See [`examples/roblox/04_server_shutdown.server.luau`](../../examples/roblox/04_server_shutdown.server.luau).
Roblox documents `BindToClose()` as the shutdown hook used for final player-data
work: <https://create.roblox.com/docs/reference/engine/classes/DataModel/BindToClose>.

## 14. Keep Actor boundaries explicit

Parallel Luau uses Actors as execution-isolation units. Fibers should initially
run one independent world inside each Actor rather than attempting a single
transaction across several Actors.

```text
Actor: world simulation
└── one Fibers runtime

Actor: navigation
└── one Fibers runtime

Actor: crowd simulation
└── one Fibers runtime
```

Actors exchange explicit messages. Those messages become external feeds or
ordinary host-backed resources in the receiving Fibers world.

This boundary is conservative and understandable:

- transactional commit remains local to one runtime;
- cross-Actor communication remains asynchronous;
- custody does not silently span isolated Luau VMs;
- parallelism is a host deployment choice, not a change to option semantics.

Roblox's current Parallel Luau model and Actor APIs are documented at
<https://create.roblox.com/docs/scripting/multithreading> and
<https://create.roblox.com/docs/reference/engine/classes/Actor>.

## 15. Make Studio show the hidden world

Fibers has enough semantic structure to support a useful Studio inspector. A
first tool could display:

```text
opening-cinematic
├── camera-track             running
├── dialogue                 cancelled: player skipped
├── npc-blocking             settled
└── camera-handle            moved → player-gameplay

selected world
├── branch                   skipped
├── reason                   player pressed Skip
└── defeated occurrence      completed
```

For AI, show:

```text
attack                       Retry: target not visible
or_else take cover           Hit
or_else patrol               not entered
```

For a transaction, show provisional and committed changes:

```text
silver keys                  1 → 0
Moon Gate                    locked → open
world                         committed
```

This is not merely debugging decoration. It exposes the same natural-language
structure which made the mechanic readable in source.

## 16. Suggested Roblox integration milestones

The first host slice is now present:

- `Roblox.prepare`, which exposes the bounded non-blocking `advance` boundary;
- `Roblox.attach`, with event-driven and RunService-phase scheduling policies;
- separate host time horizons and resumable proof-work quanta;
- queued external delivery without solver re-entry;
- `RBXScriptSignal` subscriptions held in custody, with queued, latest and pulse modes;
- `BindToClose` cancellation and Closure;
- portable fake scheduler, signal, phase and DataModel tests;
- Studio-facing examples.

The next disciplined milestones are:

1. package the generated strict Luau tree for Wally/Rojo projects;
2. run the Studio examples against the actual engine and add a smoke place;
3. add a polished scene using real camera, animation, subtitle and input APIs;
4. model player-session and match resources in a substantial prototype;
5. add promise/callback adapters for DataStore, HTTP and asset loading;
6. add a small Studio inspector for scopes, tasks and selected worlds;
7. evaluate the API with gameplay developers who did not design Fibers;
8. add Actor integration only after the single-world host is settled.

Roblox's `task` library already schedules functions and coroutines through the
engine scheduler: <https://create.roblox.com/docs/reference/engine/libraries/task>.
The adapter uses that scheduler to arrange bounded future turns while retaining
Fibers' own inner fibre, transaction and lifetime model. Roblox always owns when
a turn begins and how much host time it may consume.

## 17. Rules worth keeping visible

### Direct first

Use ordinary direct methods until a mechanic needs composition.

### `choice` is permission

Either branch may win. Source order is not priority.

### `or_else` is justified preference

Fallback requires a valid present refutation. A slow or bounded search is not
absence.

### Speculative callbacks are pure

Do not play sounds, create Instances, fire remotes or mutate unmanaged tables
inside `map`, guards, transition steps or effect preparation.

### Candidate irreversible work deliberately

Use a typed effect for selected runtime obligations, or `wrap` for
participant-local post-commit work.

### One custodian for unfinished work

Scenes, players, matches, quests and live events should each have a visible
lifetime boundary.

### Failed cleanup remains real

If saving, closing or returning authority fails, retain that failure as an
outstanding Closure rather than erasing it during unwinding.

## Further reading

- [`getting-started.md`](getting-started.md)
- [`direct-and-options.md`](direct-and-options.md)
- [`../advanced/option-algebra.md`](../advanced/option-algebra.md)
- [`../advanced/lifetimes-and-custody.md`](../advanced/lifetimes-and-custody.md)
- [`../advanced/ports.md`](../advanced/ports.md)
- [`../../examples/gameplay/`](../../examples/gameplay/)
- [`../../examples/roblox/`](../../examples/roblox/)
