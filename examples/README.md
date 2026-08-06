# Examples

Examples are grouped by audience and stability. Every tutorial and gameplay
file is a small standalone program which can be run from the repository root.

## Tutorial

`tutorial/` is intended to be read and run in numeric order. The sequence begins
with ordinary direct methods. `_op` forms appear only when composition gives
them a purpose, and the more specialised proof and custody facilities arrive
after the direct model is established.

The first two scenarios are deliberately generic. The sequence then ranges
across emergency systems, robotics, field communications, desktop applications,
firmware, games, servers and embedded hosts. Fibers is a concurrency language,
not a domain-specific framework.

### Foundations

| Example | Scenario and idea |
|---|---|
| `00_getting_started.lua` | a generic worker receives a command inside a child Lifetime |
| `01_direct_methods_and_options.lua` | direct status updates and their inert `_op` twins |
| `02_choice_and_timeout.lua` | emergency sensor confirmation or a precautionary deadline |
| `03_named_composition.lua` | robot localisation choice and jointly ready motion systems |
| `04_transactional_and_then.lua` | reserve a satellite uplink slot and admit a clinic session together |
| `05_transactional_spawn.lua` | start a selected desktop indexing job exactly once |
| `06_scoped_tasks.lua` | calibrate a sensor and configure a radio under one firmware start-up scope |
| `07_task_cancellation.lua` | emergency-stop a robot motion planner and inspect its exit |
| `08_transactional_state.lua` | update an incident level directly and transactionally |
| `09_mailbox_backpressure.lua` | preserve a save request under cosmetic desktop-event overload |
| `10_pulse_broadcast.lua` | a shelter radio and warning beacon observe one hazard change |

### Transactional composition

| Example | Scenario and idea |
|---|---|
| `11_certified_or_else.lua` | flank only when stamina and squad radio form a complete game-AI plan |
| `12_callback_phases.lua` | select an emergency dispatch, page responders after commit, then update the dashboard |
| `13_typed_effects.lua` | commit a radio configuration, merge driver obligations and reject an unsupported candidate |
| `14_defeat_obligations.lua` | retire an incompatible robot trajectory when a cautious route wins |
| `15_each_and_together.lua` | reserve motor/vision capacity, then hand off a control word |

### Lifetimes and supervision

| Example | Scenario and idea |
|---|---|
| `16_nursery_failure.lua` | a failed flood controller cancels public warnings and the incident body |
| `17_supervisor_collect.lua` | an optional desktop thumbnailer fails while search remains healthy |
| `18_memory_stream.lua` | an embedded plugin reports to its native host through a Stream held in custody |
| `19_custody_move.lua` | hand camera control from a cinematic to gameplay |

### I/O, hosts and larger patterns

| Example | Scenario and idea |
|---|---|
| `20_pipe.lua` | pipe I/O under custody |
| `21_socket.lua` | Stream sockets under custody |
| `22_resolver.lua` | name resolution and dialling under custody |
| `23_datagram.lua` | datagram sockets |
| `24_process.lua` | child processes and communication |
| `25_external_signal_feed.lua` | a hardware sensor delivered from the host runtime |
| `26_shared_deadline.lua` | one firmware boot deadline across sensor and radio stages |
| `27_service_supervision.lua` | dispatch-engine exit versus operations-centre shutdown |
| `28_robot_dispatch.lua` | reserve power, confirm safety and dispatch a field unit |

The progression is deliberate:

```text
do one thing directly
→ describe one thing as an option
→ choose and name outcomes
→ sequence and admit work transactionally
→ own and cancel concurrent work
→ compose state and bounded messaging
→ prove fallback and describe committed effects and defeat obligations
→ combine several requirements
→ supervise failure and move custody
→ apply the model across firmware, robotics, emergency systems, desktop apps,
  games, hosts and field infrastructure
```

Readers interested chiefly in application code can read `00`–`11`, then move
to `16`–`18` and `26`–`28`. Facility authors should also read `12`–`15`, `19`
and the advanced documentation.

## Gameplay

[`gameplay/`](gameplay/) develops complete mechanics rather than introducing one
API member at a time:

- a skippable cutscene whose camera, dialogue and animation close cleanly;
- a player-session lifetime;
- atomic match admission;
- an AI intention ladder based on `or_else`;
- camera custody transfer;
- supervised live-event spectacle;
- an atomic inventory/world mechanic;
- a combo input window.

These examples are portable and are intended to become shared conformance and
browser demonstrations. The companion [Roblox guide](../docs/guide/roblox.md)
maps them onto Roblox scenes, player lifetimes, host events, shutdown and Actor
boundaries.

## Roblox Studio

[`roblox/`](roblox/) exercises the experimental Roblox host adapter with real
`RBXScriptSignal`-shaped APIs:

- a manually phase-driven application with a strict host time horizon;
- an explicit event-attached application lifecycle;
- event-driven and RunService-phase scheduling above the same boundary;
- a GUI action raced against a deadline;
- a skippable cutscene under one Scope;
- a player-session lifetime;
- root cancellation and Closure through `BindToClose`;
- controlled demonstrations of queued, latest and coalesced signal modes.

These `.luau` examples require Roblox Studio and are therefore not included in
`make examples`. Their host and subscription behaviour is covered by the
portable fake-engine tests in `tests/embedding/test_roblox.lua`.

## Recipes

`recipes/` contains complete facilities built from supported public modules. The
implementation files return modules; files ending in `_example.lua` demonstrate
their use. Their tests live beside them under `recipes/tests/`.

## Embedding

`embedding/` covers external resources, the shared host reactor, readiness and
host handles.

## Lifetimes

`lifetimes/` covers effects, negotiated custody and custom Closure.

## Case studies

`case_studies/` contains trusted kernel programs such as Petri and Calendar.
They are contributor case studies, not installed version 1 modules. Their tests
live beside each case study.

Run all executable examples from the repository root:

```sh
make examples LUA=texlua
```
