# The Fibers option algebra in relation to CSP, CML, Transactional Events and Reagents

This document places the `fibers` option algebra beside four established approaches to concurrent programming:

- Communicating Sequential Processes (CSP);
- Concurrent ML (CML);
- Transactional Events (TE);
- Reagents.

The comparison is conceptual rather than a formal expressiveness result. `fibers` does not yet have published translations, separation theorems or a mechanised semantics proving that it subsumes any of these systems. The useful lineage is:

```text
CSP behavioural processes
  → CML first-class selectable synchronisation
  → Transactional Events all-or-nothing synchronisation sequences
  → Reagents atomic shared-state and message-passing reactions
  → fibers proof search for compatible committed resource worlds
```

The arrows indicate inherited questions and increasingly rich composition, not direct implementation ancestry.

## Summary

| Dimension | CSP | CML | Transactional Events | Reagents | fibers |
|---|---|---|---|---|---|
| Principal semantic object | Continuing process behaviour | One selectable event | Transactional event programme | Atomic concurrent function/reaction | One inert option denoting compatible committed worlds |
| Main interaction | Events and synchronous channels | Two-party rendezvous | All-or-nothing sequences of rendezvous | Atomic-reference updates and synchronous swaps | Versioned state, exchange, recruitment, custody and consequences |
| Alternative | Internal/external process choice | Nondeterministic event choice | Nondeterministic transactional choice | Optionally left-biased choice | Unordered `choice`; validated priority through `or_else` |
| Sequencing | Prefix and process sequencing | Work before or after one selected event | Transactional `thenEvt` | End-to-end composition | Transactional `and_then` |
| Side-by-side conjunction | Parallel process composition | No general event product | Usually encoded through sequence | Pairing `*` | Independent `each` and interacting `together` |
| Shared state | Modelled as processes | Commonly hidden behind server threads | Encodable over events | Native atomic updates | Native versioned locations and transition algebras |
| Failure information | Traces, refusals and divergence in semantic models | Event not presently selectable | Transactional search failure | `Block` and transient implementation `Retry` | `Hit`, proof-bearing `Retry` and bounded-search `Unknown` |
| Primitive-authoring centre | Process definitions and refinements | Event-valued protocols | Transactional channel protocols | Scalable lock-free data structures | Trusted declarative transactional facilities |
| Principal implementation aim | Specification and protocol reasoning | Practical selective communication | Composable atomic protocols | Parallel scalability and lock-free progress | Correct cross-resource coordination in one runtime domain |

## 1. CSP

### Algebra

CSP is an algebra of continuing process behaviours. Prefix, choice, parallel composition, hiding and recursion describe possible observations over time. Mature CSP models support reasoning about traces, refusals, deadlock and divergence, with refinement used to compare specifications and implementations.

A `fibers` option has a different extent. It describes one attempted atomic transition rather than the complete future behaviour of a process. Persistent behaviour is written as fibres which repeatedly perform options, whereas persistence is intrinsic to a recursive CSP process.

CSP parallel composition and a `fibers` product should not be identified:

```text
CSP parallel       combines continuing processes and their event alphabets
fibers product     combines lanes participating in one candidate commit
```

CSP is consequently stronger as a behavioural specification and refinement theory. `fibers` is more directly an executable calculus of atomic resource changes.

### Primitive authoring

A CSP author normally builds a resource or protocol as another process expression. Adding a new observable event is easy at the model level, but giving it new host-level optional behaviour generally belongs to the CSP implementation or to a translation into existing processes.

`fibers` instead exposes a fixed internal programme language for trusted facilities. A facility author supplies a transition, witness cursor, exchange or observation while the common kernel owns search, rollback, validation and commit.

### Expressivity

CSP naturally expresses long-lived protocols, concealment, recursive topologies and behavioural properties over complete histories. `fibers` naturally expresses one atomic world containing several state changes, participants and consequences. Neither advantage is a simple subset relation.

## 2. Concurrent ML

### Algebra

CML makes synchronous events first-class values. Events can be passed around and combined before being submitted to `sync`. Characteristic operators include event choice, wrapping after selection, delayed construction and negative-acknowledgement handling.

Approximate correspondences are:

| CML | fibers |
|---|---|
| event value | inert `Op` |
| `choose` | `choice` |
| `wrap` | `wrap` |
| `guard` | `guard`, or `and_then` where construction is transactional |
| `withNack`/`wrapAbort` | occurrence defeat obligations |
| channel send/receive | `Rendezvous` put/get |

CML event choice is nondeterministic when several events can proceed. The revised `Op.choice` has the same important algebraic intention: branch position does not confer priority. `fibers` uses a deterministic seed-derived traversal for reproducibility, but this is runtime policy rather than source-order semantics.

Fibers gives `guard` an activation-scoped interpretation. Each structural use is prepared independently, so `together({ g, g })` evaluates a reused guard twice, while one outer guard may deliberately construct a shared option. A guard returned by `and_then` is evaluated when that particular provisional progression activates. Its builder receives a short-lived activation view and returns an explicit residual operation; the view is closed immediately afterwards. The residual is then retained while the same progression is searched, suspended or reconstructed. This resembles CML pre-synchronisation preparation while accounting for Fibers' multi-step speculative worlds.

The main difference is CML's single selected synchronisation point. Work may be arranged before or after that point, but a compound protocol must still decide which communication constitutes commitment. `fibers.and_then` keeps earlier state changes and exchanges provisional until the complete continuation and all recruited participants close.

### Primitive authoring

CML is effective for application-level event abstraction. Buffered channels, remote calls and selectable protocols can be built from channels and event combinators. Implementing a new base event with its own polling, blocking and cancellation behaviour is more closely tied to the runtime selection mechanism.

In `fibers`, trusted primitive authors do not implement their own scheduler protocol. They compile facilities to the closed IR and provide lawful callbacks. This is broader than ordinary CML event composition, but it imposes purity, determinism and completeness obligations on facility code.

### Expressivity

Relative to CML's core event model, `fibers` directly adds:

- transactional continuation across several synchronisations;
- native versioned state;
- multi-participant recruitment;
- global witness and partner backtracking;
- independent and interacting n-ary products;
- proof-certified immediate fallback;
- post-commit consequences selected with the complete world.

CML remains appreciably simpler to explain and has a mature practical account of selective synchronous communication.

## 3. Transactional Events

### Algebra

Transactional Events add all-or-nothing sequencing to first-class synchronous events. `thenEvt` tentatively completes one event and continues to another; none of the sequence commits unless the complete transactional event succeeds. Together with event choice and always/never events, the system has a monadic transactional event structure.

The closest correspondences are:

| Transactional Events | fibers |
|---|---|
| `alwaysEvt` | `always` |
| `neverEvt` | `never` |
| `chooseEvt` | unordered `choice` |
| `thenEvt` | `and_then` |
| `sync` | `perform` |

Both systems admit a search-and-backtracking account: apparently completed communications remain tentative while later parts of the transaction are explored.

`fibers` extends this shape in four principal directions.

First, it has native versioned resource transitions rather than a core centred on synchronous channels. Secondly, it has side-by-side products as well as monadic sequence. Thirdly, it distinguishes independent `each` from interacting `together`. Fourthly, its bounded implementation exposes `Unknown` rather than treating a failure to complete search as a semantic refutation.

### Choice and priority

Transactional Events choice is nondeterministic rather than left-biased. That aligns with the revised `Op.choice`.

Priority in `fibers` is not encoded by branch position. It is expressed through:

```lua
preferred:or_else(Op.choice(a, b, c))
```

The fallback tier is admitted only after the preferred transactional scope has produced a complete, revalidatable `Retry` proof. This separates indifference within a tier from justified priority between tiers.

### Primitive authoring

Transactional Events make compound channel protocols much easier to author than CML. Guarded receive and multi-stage request/reply arrangements can remain local event programmes rather than manually managed cancellation protocols.

The original core does not provide the same general facility-authoring substrate as `fibers`. Stateful resources can be encoded using channel protocols or added beneath the event implementation. `fibers` instead lets a trusted facility describe versioned transitions, claims, finite or lazy witnessed successors, exchanges and host observations directly.

### Expressivity

Transactional Events has a published strict expressiveness result over CML, based in part on higher-arity rendezvous constructions which cannot be encoded in the corresponding CML model. `fibers` appears able to express the same examples, but this repository does not claim the result formally. A future semantics should include an explicit translation from Transactional Events into the compact option language.

## 4. Reagents

### Algebra

Reagents are the closest comparison in breadth. Their core combines atomic shared-state updates and synchronous communication with choice, sequencing, side-by-side pairing and post-commit work.

Approximate correspondences are:

| Reagents | fibers |
|---|---|
| `upd`/atomic update | versioned location transition or patch |
| `swap` | exchange |
| choice `+` | `choice`, but with different bias |
| sequencing `>>` | `and_then` |
| pairing `*` | product |
| `postCommit` | consequence or wrap, depending on custody |
| blocking partial update | a primitive whose complete absence contributes `Retry` |

Reagent choice is deliberately left-biased in order to support algorithms such as elimination backoff. `Op.choice` is instead unordered. A correctness-relevant preference is stated using `or_else`; a throughput preference which does not require refutation should remain runtime policy rather than changing the denotation of the option.

The principal algebraic distinction introduced by `fibers` is the split between two product modes:

```text
each      every lane must succeed and stand on its own
together  every lane must succeed and compatible siblings may support one another
```

Reagent pairing makes constituent reactions atomic together. `fibers` additionally makes the isolation-versus-interaction boundary explicit and asks each store algebra to provide separate sequential, independent-parallel and interacting-parallel composition rules.

### Primitive authoring

Reagents are designed for authors of scalable concurrent data structures. The author describes updates, reads, CAS-style actions, exchanges and composition; the implementation supplies retry, blocking and multi-location atomicity. Their performance objective is close to hand-written lock-free algorithms on multicore shared memory.

`fibers` asks a different question. A facility author describes a declarative transactional transition relation, possibly with lazy alternative witnesses. The kernel performs global proof search, participant recruitment and a serial validated commit.

| Concern | Reagents | fibers |
|---|---|---|
| Author describes | Fine-grained concurrent algorithm | Transactional resource relation |
| Execution centre | Distributed CAS/kCAS-style reaction | Runtime-local search and commit authority |
| Main correctness burden | Atomic composition and lock-free interaction | Callback purity, complete witnesses and merge laws |
| Main performance risk | Contention and CAS retries | Branching, recruitment and witness search |
| Natural domain | Parallel concurrent data structures | Rich cross-resource coordination |

### Expressivity

Reagents are stronger in the intended domain of parallel, lock-free implementation and persistent reusable catalysts. `fibers` is stronger in its direct vocabulary for proof-bearing fallback, explicit bounded-search incompleteness, custody movements and the distinction between independent and interacting conjunction.

A formal relationship between Reagent pairing and `Op.each`/`Op.together` remains open work.

## 5. The distinctive fibres algebra

The compact public basis can be read as:

```text
choice      unordered disjunction: any compatible alternative is acceptable
or_else     justified priority: fallback requires a valid refutation
and_then    transactional causality: later proof may retract earlier work
each      independent conjunction: every lane stands on its own
together  interacting conjunction: compatible sibling hand-off is visible
```

The corresponding search outcomes are:

```text
Hit       constructive evidence for a candidate committed world
Retry     complete present refutation under managed, revalidatable facts
Unknown   bounded search has established neither Hit nor Retry
```

This makes several common decisions concise.

### Priority followed by indifference

```lua
preferred:or_else(Op.choice(a, b, c))
```

Use the preferred option whenever it can commit in the selected world. Otherwise choose any acceptable option in the second tier.

### A tier of preferred alternatives followed by fallback

```lua
Op.choice(socket_a, socket_b):or_else(timeout)
```

The timeout is admitted only after both socket alternatives have been completely refuted at the relevant managed instant.

### Joint requirements without hand-off

```lua
Op.each({ account_a:take_op(1), account_b:take_op(1) })
```

Both withdrawals must be supported by the parent world; one lane cannot fund the other.

### Intentional transactional hand-off

```lua
Op.together({ slots:give_op(1), slots:take_op(1) })
```

Compatible sibling supply may participate in the same committed world.

## 6. Present strengths and limitations

`fibers` is strongest where a programme needs one coherent decision across several kinds of managed resource:

- synchronous exchange;
- state transitions and allocation;
- alternative witnesses;
- custody and Lifetime changes;
- readiness and timer observations;
- selected post-commit obligations.

The present system does not yet provide:

- a denotational semantics or mechanised proof;
- a behavioural refinement relation comparable with mature CSP work;
- a published encoding or separation theorem for the systems above;
- fairness or uniform-probability guarantees for `choice`;
- lock-free or parallel commit progress comparable with Reagents;
- static enforcement of primitive callback purity and witness completeness;
- crash-durable or distributed transactions.

The most useful formal development would therefore concentrate on:

1. translations of CML and Transactional Events into the compact option language;
2. a precise relationship between Reagent pairing and `each`/`together`;
3. laws for unordered `choice`, proof-certified `or_else` and occurrence-sensitive defeat;
4. soundness and completeness statements for `Hit`, `Retry` and `Unknown`;
5. a separation example showing why independent and interacting product modes are both necessary.

## References

Primary sources used for this comparison:

- C. A. R. Hoare, *Communicating Sequential Processes*, Prentice Hall, 1985. Oxford CSP resources: <https://www.cs.ox.ac.uk/activities/concurrency/books/>
- John H. Reppy, “CML: A Higher-order Concurrent Language”, PLDI 1991: <https://www.cs.tufts.edu/~nr/cs257/archive/john-reppy/cml-pldi.pdf>
- Kevin Donnelly and Matthew Fluet, “Transactional Events”, ICFP 2006: <https://www.cs.cornell.edu/people/fluet/research/tx-events/ICFP06/icfp06.pdf>
- Aaron Turon, “Reagents: Expressing and Composing Fine-Grained Concurrency”, PLDI 2012: <https://aturon.github.io/academic/pldi-2012-reagents.pdf>

The reference list is deliberately limited to primary material. The terminology used for `fibers` is defined in `../advanced/option-algebra.md` and `../contributing/trusted-resource-programmes.md`.
