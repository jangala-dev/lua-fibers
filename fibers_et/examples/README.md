# Examples

These files are intended to be read as small usage guides.  They should run
successfully, but assertion-heavy regression cases belong in `tests/`.

Run an example from the repository root with:

```sh
lua examples/01_channel.lua
```

The examples build up the public base kit:

```text
01_channel.lua          Channel rendezvous and ordinary fibres
02_cell.lua             Cell as transactional state
03_source.lua           Source as host/time/external occurrence
04_lifetime_task.lua    Lifetime-owned Task and await
05_effect.lua           Effect as an after-commit obligation
06_policy_nursery.lua   Policy-aware structured spawn
07_lifetime_handoff.lua Lifetime ownership handoff
08_sleep.lua            Sleep facility over the host clock, using the pure Lua host
09_memory_stream.lua    Transactional in-memory stream read/write/EOF
10_stream_protocol_handoff.lua Transactional protocol negotiation and ownership handoff
11_pumped_stream_fake_backend.lua Host-pumped stream using the fake backend
12_readiness_stream.lua Readiness-backed fake host stream
13_socket_backend_contract.lua Socket-shaped backend over a manual host adapter
```
