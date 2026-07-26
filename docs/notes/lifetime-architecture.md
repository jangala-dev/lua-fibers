# Lifetime architecture

The production architecture has two semantic centres:

```text
Op
  possible committed worlds

Lifetime
  continuing consequences under custody
```

Each Runtime owns one transactional Lifetime store. The store is an ordered
forest with one custodial parent per live node. Task, Scope and domain resources
are capability views over nodes:

```text
Task ──────┐
Scope ─────┼──▶ Lifetime node
Process ───┘
```

The advanced Lifetime surface has three laws:

```text
Custody
  the unique tree of responsibility

Grant
  non-custodial authority represented by ordinary Lifetime nodes

Closure
  local shutdown, child propagation, ordered finishing and recovery
```

Host holds and close tokens are private implementation devices. There is no
public close-token, separate temporary-authority API or propagation-policy subsystem.

Driven domain resources use one Lifetime layer over host providers. For example:

```text
Process Lifetime
├── host-process handle
├── stdin/stdout/stderr Streams
├── bridge Tasks
└── reaper work
```

The provider supplies irreversible host mechanisms. The Process Lifetime owns
custody, Grants, milestones, cancellation and Closure independently of the host
strategy.

Body result, domain result and complete Lifetime outcome remain distinct.
Closure failure retains custody and irreversible progress until retry or force
finishes the unresolved subtree.
