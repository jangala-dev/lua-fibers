# Examples

Examples are grouped by audience and stability. Every tutorial file is a small,
standalone programme which can be run from the repository root.

## Tutorial

`tutorial/` is intended to be read and run in numeric order. The sequence begins
with ordinary direct methods. `_op` forms appear only when composition gives
them a purpose, and the more specialised proof and ownership facilities arrive
after the direct model is established.

### Foundations

| Example | Introduces |
|---|---|
| `00_getting_started.lua` | direct communication, fibres and scope ownership |
| `01_direct_methods_and_options.lua` | the direct method and inert `_op` pairing |
| `02_choice_and_timeout.lua` | unordered `choice` and an ordinary timeout branch |
| `03_named_composition.lua` | readable results from `named_choice` and `named_all` |
| `04_transactional_and_then.lua` | value-dependent transactional sequencing |
| `05_transactional_spawn.lua` | task admission as part of the committed world |
| `06_scoped_tasks.lua` | task results and structured lifetime boundaries |
| `07_task_cancellation.lua` | explicit cancellation and inspectable task exits |
| `08_transactional_state.lua` | direct and composable Scalar state |
| `09_mailbox_backpressure.lua` | bounded mailboxes, close and overload policy |
| `10_pulse_broadcast.lua` | coalescing broadcast notification |

### Transactional composition

| Example | Introduces |
|---|---|
| `11_certified_or_else.lua` | proof-directed fallback and rollback of provisional work |
| `12_callback_phases.lua` | speculative callbacks, pure preparation, discharge and `wrap` |
| `13_defeat_obligations.lua` | typed obligations attached to losing occurrences |
| `14_all_and_tensor.lua` | conservative conjunction and intentional sibling hand-off |

### Lifetimes and supervision

| Example | Introduces |
|---|---|
| `15_nursery_failure.lua` | fail-fast child failure, sibling cancellation and reports |
| `16_supervisor_collect.lua` | collecting independent child failures without failing the body |
| `17_memory_stream.lua` | in-memory duplex streams |
| `18_custody_move.lua` | transactional protocol state and ownership movement |

### I/O, hosts and larger patterns

| Example | Introduces |
|---|---|
| `19_pipe.lua` | owned pipe I/O |
| `20_socket.lua` | owned stream sockets |
| `21_resolver.lua` | owned name resolution and dialling |
| `22_datagram.lua` | datagram sockets |
| `23_process.lua` | child processes and communication |
| `24_external_signal_feed.lua` | host delivery into a Fibers runtime |
| `25_shared_deadline.lua` | one absolute deadline across several stages |
| `26_service_supervision.lua` | service exit versus administrative shutdown |
| `27_robot_dispatch.lua` | a fuller cross-resource decision |

The progression is deliberate:

```text
do one thing directly
→ describe one thing as an option
→ choose and name outcomes
→ sequence and admit work transactionally
→ own and cancel concurrent work
→ compose state and bounded messaging
→ prove fallback and attach committed obligations
→ combine several requirements
→ supervise failure and move custody
→ apply the model to I/O, hosts and services
```

Readers interested chiefly in application code can read `00`–`11`, then move
to `15`–`17` and `25`–`27`. Facility authors should also read `12`–`14`, `18`
and the advanced documentation.

## Recipes

`recipes/` contains complete facilities built from supported public modules. The
implementation files return modules; files ending in `_example.lua` demonstrate
their use. Their tests live beside them under `recipes/tests/`.

## Embedding

`embedding/` covers external resources, the shared host reactor, readiness and
host handles.

## Lifetimes

`lifetimes/` covers effects, negotiated custody and custom settlement.

## Case studies

`case_studies/` contains trusted kernel programmes such as Petri and Calendar.
They are contributor case studies, not installed version 1 modules. Their tests
live beside each case study.

Run all executable examples from the repository root:

```sh
make examples LUA=texlua
```
