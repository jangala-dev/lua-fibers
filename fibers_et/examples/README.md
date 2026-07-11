# Examples

These files are intended to be read as small usage guides.  They should run
successfully, but assertion-heavy regression cases belong in `tests/`.

Run an example from the repository root with:

```sh
texlua examples/01_rendezvous.lua
```

The examples build up the public atom kit:

```text
01_rendezvous.lua          Rendezvous meeting and ordinary fibres
02_scalar.lua           Scalar as transactional state
03_external_resources.lua Signal, Clock and external feed capabilities
04_scope_task.lua    Scope-owned Task and await
05_effect.lua           Effect as an after-commit obligation
06_policy_nursery.lua   Policy-aware structured spawn
07_scope_custody_offer.lua Negotiated scope custody offer
08_sleep.lua            Sleep facility over the host clock, using the pure Lua host
09_memory_stream.lua    Transactional in-memory stream read/write/EOF
10_stream_protocol_move.lua Transactional protocol negotiation and custody movement
11_pumped_stream_fake_backend.lua Host-pumped stream using the fake backend
12_readiness_stream.lua Readiness-backed fake host stream
13_socket_backend_contract.lua Socket-shaped backend over a manual host adapter
14_host_handle_stream.lua Generic HostHandle-backed stream over manual host
15_owned_resource_settlement.lua Resource-author Owned settlement protocol
```

16_rate_limiter.lua       Token-bucket rate limiter over typed Scalar transitions
17_scalar_flow.lua         Scalar-state-machine Flow and tensor handoff
