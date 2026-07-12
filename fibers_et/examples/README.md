# Examples

These files are small usage guides. Assertion-heavy regression cases belong in `tests/`.

Run an example from the repository root:

```sh
lua examples/01_rendezvous.lua
luajit examples/01_rendezvous.lua
texlua examples/01_rendezvous.lua
```

```text
01_rendezvous.lua               synchronous exchange and ordinary fibres
02_scalar.lua                   Scalar transactional state
03_external_resources.lua       Signal, Clock and runtime-bound feeds
04_scope_task.lua               Scope-owned Task and await
05_effect.lua                   typed post-commit effect
06_policy_nursery.lua           nursery policy and structured spawn
07_scope_custody_offer.lua      negotiated custody movement
08_sleep.lua                    sleep over the pure host clock
09_memory_stream.lua            in-memory Stream read, write and EOF
10_stream_protocol_move.lua     protocol negotiation and custody movement
11_pumped_stream_fake_backend.lua host-pumped Stream with fake backend
12_readiness_stream.lua         readiness-backed fake-host Stream
13_socket_backend_contract.lua  socket-shaped manual backend
14_host_handle_stream.lua       HostHandle-backed Stream
15_owned_resource_settlement.lua custom Region.Owned settlement
16_rate_limiter.lua             token-bucket Scalar machine
17_scalar_flow.lua              Flow state machine and tensor hand-off
```

Petri and Calendar are covered in the programming guide and their focused tests; they do not yet have numbered examples.
