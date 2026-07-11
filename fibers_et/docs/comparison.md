# Comparison with CSP, CML, Transactional Events and Reagents

This document places the `fibers` model in its principal concurrency lineage. It
is an orientation guide, not an expressiveness proof: each comparison concerns
the characteristic core of the cited system, and implementations or later
variants may provide additional facilities.

The short account is:

```text
CSP                  processes communicate and synchronise
CML                  synchronisations become first-class values
Transactional Events sequences of synchronisations become all-or-nothing
Reagents              shared-state updates and synchronous exchanges compose
fibers                open resources contribute to candidate committed worlds
```

The closest technical precedent is Reagents. `fibers` differs chiefly in making
resource participation open, making bounded search outcomes explicit, and using
the same transaction machinery to govern structured task and resource lifetime.

## At a glance

| Model | Primary compositional unit | Communication | Shared state | Atomic composition | After commit | Extension boundary |
| --- | --- | --- | --- | --- | --- | --- |
| CSP | Process expression | Synchronous input and output between processes | Normally local process state | Process sequencing, parallel composition and guarded alternatives; not a general transaction | Ordinary continuation of the selected process | New processes and protocols |
| CML | First-class event | Synchronous channel event | Ordinary host-language state outside the event commit | Choice among events; one selected synchronisation is the commit point | `wrap` runs a participant action after synchronisation | New event abstractions built from event combinators and server protocols |
| Transactional Events | First-class transactional event | Synchronous channel events | Encodable transactionally; not an open resource protocol | `thenEvt` sequences several communications all-or-nothing | Event result and subsequent participant code | New transactional event protocols |
| Reagents | `Reagent[A,B]` | Synchronous endpoint swap | Atomic reference update | Choice, sequencing and pairing combine updates and exchanges | `postCommit`; persistent catalyst invocation is also provided | Composition over the fixed `upd` and `swap` foundations |
| `fibers` | First-class `Op` denoting candidate worlds | Rendezvous resources, including multi-party closure | Resource-specific speculative journals | `and_then`, choice, independent and interacting products, and certified fallback | Commit consequences, defeat consequences and participant `wrap`s are distinct | New resource kinds define requests, solving, validation, preparation and application |

## CSP

[Hoare's original CSP proposal](https://www.cs.cmu.edu/~crary/819-f09/Hoare78.pdf) treats input and output as programming primitives
and parallel composition of communicating sequential processes as a fundamental
structuring method. Guarded commands provide conditional and nondeterministic
selection, including guards whose readiness depends on communication. A parallel
command terminates when all its constituent processes have terminated.

The enduring CSP contribution to this lineage is the view that synchronous
communication is both data transfer and control: the parties proceed together,
and guarded alternatives can make communication readiness part of programme
structure.

`fibers` retains that interaction model in `Rendezvous`, but changes the unit of
composition:

```text
CSP       compose processes whose commands communicate
fibers    compose inert operation values which may later recruit fibres and resources
```

An `Op` can be stored, passed, selected and combined before any fibre performs
it. Its commit may also include resource journals and runtime obligations which
are not communications. Conversely, `fibers` is not offered as a replacement
for CSP's process algebra, trace models or verification tradition.

## Concurrent ML

[CML's decisive step](https://www.cs.tufts.edu/~nr/cs257/archive/john-reppy/cml-pldi.pdf) is to make synchronous operations first-class. Channel
receive and transmit produce event values; `sync` performs an event; `choose`
forms selective communication; and `wrap` associates a post-synchronisation
function with a selected event. This permits user-defined communication
abstractions such as buffered channels, RPC and multicast to be built as
libraries rather than fixed language constructs.

The direct inheritance in `fibers` is substantial:

```text
CML event value       fibers Op value
CML sync              fibers.perform
CML alwaysEvt         Op.always
CML choose            Op.choose
CML wrap              Op.wrap
CML guard             Op.guard
```

The important change is the commit boundary. A CML selection commits one base
synchronisation. Further communication performed by a wrapper is a later event.
A `fibers` candidate world may instead close several rendezvous and install
several resource journals in one commit.

CML's negative acknowledgement mechanism makes the loss of an event observable
as another event. `fibers` does not retain `withNack` in its core. A dynamic
operation occurrence may carry a typed defeat consequence, dispatched when an
entered competitor is permanently retired. An event-shaped notification can be
constructed as a library protocol when it is genuinely required.

## Transactional Events

[Transactional Events](https://www.cs.cornell.edu/people/fluet/research/tx-events/ICFP06/icfp06.pdf) address CML's single-commit-point limitation. Their
`thenEvt` combinator tentatively completes one event and constructs the next;
the entire sequence either synchronises or aborts. Together with transactional
choice, this supports modular guarded receive, multi-way rendezvous and other
protocols which are difficult to package using CML alone.

`Op:and_then` follows the same central intuition: the value proved by one
part of an operation may construct the remainder of the same transaction.
Neither prefix commits independently.

The difference is what may inhabit the transaction. The characteristic TE
substrate is synchronous events, with richer facilities encoded through event
protocols. A `fibers` primitive addresses an open transactional resource:

```text
primitive(resource, request)
```

A resource kind may contribute tentative state, matching or allocation
premises, validation observations and commit consequences. Rendezvous is one
resource family rather than the privileged definition of a transaction.

`fibers` also distinguishes eager competition from certified fallback:

```text
choose(p, q)      both alternatives compete
or_else(p, q)     q is opened only after p yields a valid Retry proof
```

A bounded search which has not finished returns `Unknown`, not `Retry`, and
therefore cannot enable `or_else`. This distinction has no direct counterpart in
the core TE interface.

## Reagents

[Reagents](https://aturon.github.io/academic/reagents.pdf) are the nearest precedent in both ambition and structure. A
`Reagent[A,B]` is an inert concurrent transformation which may combine atomic
shared-state updates with synchronous endpoint exchanges. The core includes:

```text
upd          isolated atomic reference update
swap         synchronous exchange
+            choice
>>           sequencing
*            pairing
postCommit   action after a successful reaction
```

Reagents explicitly connect shared state with message passing, or isolation
with interaction. They also distinguish active one-shot invocation from passive
persistent catalysts. Their implementation goal is fine-grained shared-memory
parallelism with a clear cost model and performance competitive with specialised
lock-free algorithms.

`fibers` agrees with the central Reagents claim that useful concurrent
abstractions often need both isolation and interaction. There are nevertheless
material differences.

### Open resources rather than two foundational interactions

Reagents deliberately build from atomic reference updates and synchronous
swaps. `fibers` exposes a resource protocol. Standard instances include scalar,
counter, ordered, keyed, leasing, rendezvous, external-event and ownership
resources. A resource may solve a domain-specific set of combined requests
rather than reducing every interaction to a reference update or endpoint swap.

This openness has a cost: writing a lawful advanced resource is closer to
writing part of a transaction engine than to implementing an ordinary Lua
object. `fibers` therefore does not inherit Reagents' compact cost model merely
by resemblance.

### Two product modes

Reagent sequencing and pairing conjoin interactions. `fibers` makes a further
operational distinction:

```text
all       lanes are jointly committed but may not satisfy one another

tensor    lanes form a local interaction network and may close internal
          rendezvous or positive resource supply
```

This separates joint allocation from internal handoff. It is a deliberate
semantic distinction, not merely an API spelling of pairing.

### Proof-carrying retry and bounded search

Reagents distinguish transient interference, which should retry immediately,
from permanent failure, which should block until the environment changes.
`fibers` expresses the corresponding completed-search result as `Retry P`, where
`P` records managed validity frontiers and host interests.

It adds a separate `Unknown K` result for bounded or incomplete search. This
allows an embeddable runtime to suspend proof work without pretending that the
operation is currently impossible.

### Outcome scope

Reagents provide `postCommit`, and therefore precede `fibers` in attaching work
to a successful reaction. `fibers` divides outcome behaviour more finely:

```text
resource journal       state installed by the commit
commit consequence     runtime obligation selected with the world

defeat consequence     runtime obligation of an entered losing occurrence
wrap                    value transformation run by one resumed participant
```

The distinction is about ownership and ordering, not a claim that post-commit
actions are new.

### Lifetime as a transactional application

Reagents provide persistent catalysts, while their core paper leaves catalyst
cancellation as an addition. `fibers` currently lacks an equivalent general
passive-reaction operator. Instead, its developed lifetime application is
structured scopes: task admission, custody movement, cancellation, closure and
settlement are represented through ordinary resource transactions and policy.

This is one of the model's intended demonstrations: structured concurrency is
not a separate scheduler convention, but a policy over transactionally recorded
obligations. It does not imply that CSP, CML, TE or Reagents cannot host
structured concurrency by other means.

## Where `fibers` is deliberately different

The model can be summarised by five choices.

### The transaction denotes a world, not only an event sequence

A candidate world may contain communication, state changes, ownership changes,
external observations and runtime obligations. Commit selects one compatible
world and makes those components real together.

### Resource semantics are open

The runtime does not know all resource algebras in advance. Resource kinds own
their request composition, solving and journal semantics, subject to global
validity and commit laws.

### Search outcomes carry semantic information

`Hit`, `Retry` and `Unknown` are distinct. In particular, incomplete bounded
search is not interpreted as absence and cannot trigger fallback.

### Participant continuation is not transaction consequence

A `wrap` belongs to one resumed fibre. A consequence belongs to the selected
world or defeated occurrence and is discharged by the runtime before ordinary
participant continuation.

### Lifetime is governed by policy over recorded custody

Scopes account for tasks and resources before their boundaries complete.
Nursery, supervisor and custom policies determine failure propagation while the
Region ledger records custody.

## Non-claims

The comparison should not be read as claiming that `fibers` strictly subsumes
these systems.

- It does not provide CSP's established process-algebraic verification model.
- It does not adopt CML's exact scheduling, fairness or event semantics.
- Its algebra is not simply TE's monad-with-plus: `or_else`, product modes,
  consequences and bounded `Unknown` add different structure and laws.
- It does not currently provide Reagents' lock-free progress or performance
  guarantees, nor a general catalyst facility.
- Its guarantees are in-process. Commit consequences are not crash-durable
  distributed transactions.

The intended position is narrower:

> `fibers` is a cooperative Lua runtime for first-class transactions over
> extensible resources, combining synchronous interaction, speculative state,
> proof-carrying retry, runtime consequences and structured lifetime.

## Primary references

- C. A. R. Hoare, [“Communicating Sequential Processes”](https://www.cs.cmu.edu/~crary/819-f09/Hoare78.pdf), *Communications of the ACM*, 1978.
- John H. Reppy, [“CML: A Higher-order Concurrent Language”](https://www.cs.tufts.edu/~nr/cs257/archive/john-reppy/cml-pldi.pdf), PLDI 1991.
- Kevin Donnelly and Matthew Fluet, [“Transactional Events”](https://www.cs.cornell.edu/people/fluet/research/tx-events/ICFP06/icfp06.pdf), ICFP 2006.
- Aaron Turon, [“Reagents: Expressing and Composing Fine-grained Concurrency”](https://aturon.github.io/academic/reagents.pdf), PLDI 2012.
