# Fibers tutorial

Run these files from the repository root in numeric order. Each is intentionally
small enough to read as a complete program and contains assertions for the
behaviour it demonstrates.

The first two programs are deliberately generic. The remaining examples
move through emergency coordination, robotics, field communications, desktop
applications, firmware, games, servers and embedded hosts. The domains change;
the concurrency vocabulary does not.

The tutorial has four stages:

1. **Foundations (`00`–`10`)** — generic commands and options, emergency timing,
   robot localisation, field-network admission, desktop task admission,
   firmware start-up, cancellation, transactional state, backpressure and
   broadcast hazard changes.
2. **Transactional composition (`11`–`15`)** — game AI preference, callback
   phases, typed committed effects, robot trajectory defeat obligations, and the
   distinction between `each` and `together`.
3. **Lifetimes (`16`–`19`)** — emergency-controller failure, collecting desktop
   supervisors, plugin streams and game-camera custody.
4. **Systems work (`20`–`28`)** — pipes, sockets, resolution, datagrams,
   processes, hardware feeds, firmware deadlines, operations-centre supervision
   and field-unit dispatch.

A compact first reading is:

```text
00 → 01 → 02 → 04 → 06 → 08 → 11 → 13 → 16 → 18 → 26 → 28
```

Readers chiefly interested in game logic should continue with
[`../gameplay/`](../gameplay/) and the
[step-by-step Roblox guide](../../docs/guide/roblox.md).

The remaining examples fill in important facilities without changing the core
mental model.
