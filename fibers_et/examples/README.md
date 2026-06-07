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
04_region_task.lua      Region-owned Task and join
05_effect.lua           Effect as an after-commit obligation
```
