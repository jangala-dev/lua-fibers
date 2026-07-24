# Gameplay examples

These examples apply the ordinary Fibers vocabulary to recognisable game
mechanics. They are portable Lua programmes rather than Roblox-specific code,
so the same examples can later run under stock Lua, the generated Luau target
and a browser playground.

Read them in order:

| Example | Mechanic | Fibers idea |
|---|---|---|
| `00_skippable_cutscene.lua` | a cinematic which leaves cleanly when skipped | scene-owned tasks, `choice`, cancellation and joined exits |
| `01_player_session.lua` | work which exists only while one player is present | nested scope as the player-session lifetime |
| `02_atomic_match_admission.lua` | reserve capacity and start a match together | transactional state plus transactional task admission |
| `03_ai_intention_ladder.lua` | attack, take cover, or patrol | proof-directed `or_else` rather than timeout-driven fallback |
| `04_camera_custody.lua` | hand camera authority from a cinematic to gameplay | state change, protocol hand-off and custody movement in one transaction |
| `05_live_event_supervision.lua` | keep a live event running when an optional effect fails | collecting supervision |
| `06_unlock_the_moon_gate.lua` | consume a key and open a gate atomically | `all`, `and_then` and rollback-safe mechanics |
| `07_combo_window.lua` | accept a follow-up input before the window closes | ordinary `choice` between input and time |

The step-by-step Roblox guide is at
[`docs/guide/roblox.md`](../../docs/guide/roblox.md).
