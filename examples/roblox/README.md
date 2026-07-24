# Roblox examples

These Studio examples exercise the experimental bounded Roblox embedding. They
are not run by the stock-Lua example target because they require Roblox services
and `RBXScriptSignal` values.

Roblox remains the owner of scheduling and frame progression. The canonical
interface is `Roblox.prepare` plus bounded `Application:advance` calls. The
`Roblox.attach`, `run` and `try_run` helpers add scheduling convenience without
changing that boundary.

Install the generated Luau package so that these modules are available beneath
your package root:

```text
Fibers
├── init
├── op
├── sleep
├── roblox
└── ...
```

The examples use the common Wally/Rojo-style location
`ReplicatedStorage.Packages.Fibers`; adjust the first few `require` statements to
match your project.

Read them in order:

| Example | Context | Main idea |
|---|---|---|
| `00_manual_horizon.client.luau` | LocalScript | embed `prepare`/`advance` in an existing Heartbeat phase with a strict horizon |
| `01_button_choice.client.luau` | LocalScript | own an event-attached application through settlement and closure |
| `02_skippable_cutscene.client.luau` | LocalScript | let one scope own camera, dialogue and skip handling |
| `03_player_session.server.luau` | Script | make each player's work end with the player |
| `04_server_shutdown.server.luau` | Script | cancel and settle the root through `BindToClose` |
| `05_signal_modes.client.luau` | LocalScript | compare queued, latest and pulse semantics with controlled bursts before one advance |
| `06_phase_attach.client.luau` | LocalScript | advance only after a selected RunService phase |

The `prepare`/`advance` boundary is the architectural reference. Example 00
shows one manual phase-driven embedding; example 01 adds event scheduling and
explicit application settlement; example 06 adds RunService-phase policy above
the same boundary.

The full guide is [`docs/guide/roblox.md`](../../docs/guide/roblox.md).
