# Fibers tutorial

Run these files from the repository root in numeric order. Each is intentionally
small enough to read as a complete programme and contains assertions for the
behaviour it demonstrates.

The tutorial has four stages:

1. **Foundations (`00`–`10`)** — ordinary fibres first, followed by inert options,
   decisions, transactional sequencing, task admission, cancellation, state and
   messaging.
2. **Transactional composition (`11`–`14`)** — certified fallback, the three
   callback phases, defeat obligations, and the distinction between `all` and
   `tensor`.
3. **Lifetimes (`15`–`18`)** — nursery failure, supervisors, streams and custody
   movement.
4. **Systems work (`19`–`27`)** — pipes, sockets, resolution, datagrams,
   processes, external host feeds, shared deadlines and service orchestration.

A compact first reading is:

```text
00 → 01 → 02 → 04 → 06 → 08 → 11 → 15 → 17 → 25 → 27
```

The remaining examples fill in important facilities without changing the core
mental model.
