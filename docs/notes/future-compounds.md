# Future compounds

This document preserves quarry notes.  It is not an API promise.

The resource toolkit and lifetime calculus suggest larger compounds.  Some may become
facilities.  Some may remain design language.  A name earns its place only if it
reduces ambiguity in the system.

## Escrow

Law:

```text
custody may be pending without becoming ownerless
```

Implementation sentence:

```text
an escrow is a Lifetime-held pending transfer with terms, timeout and resolution
```

Possible use:

```text
protocol upgrade, session acceptance, resource migration, deferred acceptance
```

Escrow differs from direct movement.  Movement transfers custody now.  Escrow
holds custody under terms until acceptance, rejection, timeout or failure resolves
it.

## Membrane

Law:

```text
authority may cross a boundary only in declared forms
```

Implementation sentence:

```text
a membrane is a table of authority translations at a scope boundary, built from Grants, `can_op` and `move_op`
```

Possible use:

```text
subsystem APIs, safe plugin boundaries, protocol views, read-only world access
```

A membrane should not be a separate access-control side-channel.  It should be a
facility over Grants and custody.

## Covenant

Law:

```text
named obligations commit together or not at all
```

Implementation sentence:

```text
a covenant is a named tensor of terms, each contributing journals, movement, Grants or effects
```

Possible use:

```text
multi-party session acceptance, resource exchange, phase transition agreements
```

Covenant is design language until large `tensor` expressions need a more legible
shape.

## Braid

Law:

```text
flows may transform while preserving linked fate
```

Implementation sentence:

```text
a braid is a family of flows with related leases, lineage and Closure rules
```

Possible use:

```text
tee, mux, demux, compression, encryption, protocol upgrade, asset pipelines
```

A stream moves bytes.  A braid records how byte fates remain related across
several flows and transformations.

## Tomb

Law:

```text
failed Closure remains custody truth
```

Implementation sentence:

```text
a tomb is a Lifetime that retains unresolved Closure records and their retry, quarantine or force-release strategy
```

Possible use:

```text
scope shutdown reports, host handle failure, process reap failure, durable cleanup ledgers
```

Tomb should not hide failure.  It should make unresolved failure easier to keep
honestly.

## Weather

Law:

```text
the outside world may be admitted as changing condition, not only discrete event
```

Implementation sentence:

```text
weather folds externally fed resources into cell conditions with validity facts
```

Possible use:

```text
readiness, deadlines, frame budget, power state, network condition, device state
```

`Signal`, `EventQueue` and `Readiness` admit externally supplied facts.  Weather would admit current conditions whose truth
may later stop holding.

## Mirror

Law:

```text
observation may itself be maintained, valid and under custody
```

Implementation sentence:

```text
a mirror is a derived view held in custody, fed by committed events and guarded by validity
```

Possible use:

```text
scope inspection, stream diagnostics, phase debugging, live resource maps
```

Events are not the source of truth.  A mirror should be a maintained view under custody
of the underlying ledger.

## Phase

Law:

```text
time advances only when its obligations have been accounted for
```

Implementation sentence:

```text
a phase is a named scope interval with declared custody movement, authority Grants, fact propagation and Closure at the boundary
```

Possible use:

```text
game frame stages, render extraction, embedded power modes, radio awake/sleep cycles
```

The current `docs/notes/phase.lua` implementation is a prototype.  It proves that phase can be
built over scope and now enforces declared custody, authority and fact
crossings by explicit edge label.  It is still not a full phase language: it
does not yet model emitted events, active-phase ordering or richer edge policy.
