# The Fibres Algebra

This document describes the algebraic model underlying Fibres options.

The implementation is inspired by Concurrent ML, Software Transactional Memory, and Transactional Events, but the object being transacted here is broader than a memory update or a communication event. A Fibres option denotes a set of possible committed worlds. A world may contain synchronous rendezvous, transactional resource journals, source observations, ownership changes, and post-commit runtime effects.

The practical notions of `fibers` and `op`s come from Andy Wingo's work on the Snabb networking toolkit, which adapted CML-style first-class synchronisation to Lua and provided the starting vocabulary for this library.

This document is not a complete formal semantics. It is a compact statement of the model, the intended laws, and the boundaries that implementations and extensions must preserve.

## 1. Central idea

An option is not an action. It is a description of possible worlds.

```text
option     ≈  set of candidate committed worlds
runtime    ≈  search, select, prepare, commit, discharge, resume
```

A candidate world may contain:

```text
result          the value delivered if the world wins
rendezvous      synchronous handshakes between lanes or roots
journals        transactional resource changes
observations    managed facts used during proof
absence         evidence that a preferred world is unavailable
effects         runtime obligations to discharge after commit
wraps           post-commit continuations
```

The runtime searches for a compatible world. If one is selected, it commits the world atomically with respect to the runtime state:

```text
search is speculative
commit is atomic
effects are post-commit
wraps observe committed worlds
losing worlds do not apply journals or discharge effects
```

## 2. Lineage

Fibres sits in a line of ideas:

```text
CML:
  first-class synchronous events

STM:
  composable all-or-nothing memory transactions

Transactional Events:
  all-or-nothing synchronous event protocols

Fibres:
  all-or-nothing construction of worlds containing rendezvous,
  resource journals, ownership changes, source observations, and
  post-commit effects
```

The distinguishing move is that communication, state, ownership, source readiness and runtime obligations are not separate mechanisms. They are components of one committed world.

## 3. Core option language

The public API may expose convenience forms, but the core option language is small.

```text
op ::=
    always(v...)
  | choice(op₁, ..., opₙ)
  | bind(op, k)
  | or_else(primary, fallback)
  | product({ opᵢ }, allow_internal)
  | wrap(op, k)
  | guard(k)
  | with_nack(make, op)
  | emit(effect)
  | primitive(resource/source/channel option)
```

Several familiar operators are derived:

```text
never
  ≜ choice()

map(op, f)
  ≜ bind(op, λxs. always(f(xs)))

tensor({ opᵢ })
  ≜ product({ opᵢ }, allow_internal = true)

all({ opᵢ })
  ≜ product({ opᵢ }, allow_internal = false)

empty tensor/all
  ≜ always(empty_rows)
```

The public surface may keep `never`, `map`, `tensor`, and `all`; they need not be primitive in the transaction solver.

## 4. Outcomes

A solver must distinguish at least four outcomes.

```text
commit W
  A compatible world W has been found.

blocked I
  No world is available now. The runtime is waiting on interests I.

absent A
  A preferred world is certifiably absent under observations A.

unknown U
  The solver or a resource cannot certify availability or absence.
```

This distinction is essential. In particular:

```text
not found is not absence
timeout is not absence
resource staleness is not absence
bounded search failure is not absence
```

`or_else` depends on this distinction.

## 5. Worlds and commit

A world is a structured candidate.

```text
World W =
  {
    result,
    rendezvous,
    journals,
    observations,
    absence_proofs,
    effects,
    wraps
  }
```

A runtime commit has the shape:

```text
current state Σ
candidate world W
prepared resource journals J
post-commit effects E
result value v
```

Commit is valid only if:

```text
all rendezvous obligations are satisfied
all journals merge without conflict
all prepared resources are still valid
all effect keys merge or are distinct
all ownership changes preserve region invariants
all absence proofs are conservative
```

Commit then proceeds conceptually as:

```text
1. prepare resource journals
2. reject if stale or conflicting
3. apply journals
4. record committed effects
5. discharge effects
6. run post-commit wraps
7. resume selected fibres
```

The ordering may be implemented efficiently, but the semantic boundary must be preserved.

## 6. Search phase and commit phase

Fibres has two important phases.

### Search phase

Search phase constructs possible worlds. Search-phase code must be pure in the operational sense:

```text
deterministic
non-suspending
no irreversible I/O
no mutation of external state
no dependence on facts not represented as resources or sources
```

Search-phase callbacks include:

```text
bind / and_then continuations
map callbacks, as derived bind continuations
guard callbacks
resource proposal functions
nack construction
```

Search callbacks are proof code, not effect code.

### Commit phase

Commit phase applies one selected world.

Post-commit callbacks and obligations include:

```text
wrap callbacks
effect discharge
selected fibre resumption
lifetime events
host wake/spawn/interrupt obligations
```

A callback that must observe the committed world belongs in `wrap`, not in `map` or `and_then`.

## 7. `bind` and derived `map`

`bind` extends a proof using the value of a prior proof.

```text
bind(op, k)
```

If `op` proves a value `v`, then `k(v)` produces the next option in the same search.

`map` is derived:

```text
map(op, f) ≜ bind(op, λv. always(f(v)))
```

This gives the usual functor behaviour under purity:

```text
map(id, op) ≈ op

map(g, map(f, op)) ≈ map(g ∘ f, op)
```

These are conditional laws. They require `f` and `g` to be pure search-phase functions.

`bind` is more powerful than `map`: it can use a value to choose the next option and therefore change the candidate world.

## 8. `choice`

`choice` denotes alternatives.

```text
choice(op₁, ..., opₙ)
```

`never` is the empty choice:

```text
never ≜ choice()
```

Basic laws:

```text
choice() ≈ never

choice(never, op) ≈ op

choice(op, never) ≈ op

choice(choice(a, b), c) ≈ choice(a, b, c)
```

The operational scheduler may make choice order observable. Therefore, unless the scheduler contract says otherwise, `choice` should not be treated as fully commutative.

Important non-law:

```text
choice(a, b) ≠ choice(b, a)    when priority or fairness is observable
```

Losing branches do not commit journals or effects.

## 9. Product, `all`, and `tensor`

The internal product operator has two modes:

```text
product(lanes, allow_internal)
```

The public operators are:

```text
all(lanes)
  ≜ product(lanes, allow_internal = false)

tensor(lanes)
  ≜ product(lanes, allow_internal = true)
```

### `all`

`all` requires its lanes to be independently satisfiable.

```text
all({ a, b, c })
```

Each lane contributes to the result, but lanes do not satisfy one another’s rendezvous.

`all` is a value product, not an internal synchronisation product.

### `tensor`

`tensor` constructs one world with multiple lanes.

```text
tensor({ a, b, c })
```

Lanes may rendezvous with one another inside the same candidate world. Their journals, effects, ownership changes and observations merge into one atomic world.

This is the operator that makes negotiated handoff natural.

Example shape:

```lua
fibers.tensor({
  request:offer_handoff_op(session, supervisor),
  supervisor:accept_handoff_op(),
  registry:write_op({ owner = "supervisor", task = session.name }),
  audit:append_op("accepted session from request into supervisor"),
})
```

This means:

```text
the source offers
the target accepts
the registry changes
the audit records

or none of them happen
```

### Product laws

Unconditional:

```text
all({}) ≈ always(empty_rows)

tensor({}) ≈ always(empty_rows)
```

Conditional:

```text
all({ op }) ≈ op, modulo row packaging

tensor({ op }) ≈ op, modulo row packaging

tensor is associative up to lane renaming
  if resource/effect merge order is observationally irrelevant

all(lanes) ≈ tensor(lanes)
  only when no internal rendezvous is possible or required
```

Important non-law:

```text
all ≠ tensor
```

The distinction is semantic. `tensor` permits internal rendezvous; `all` does not.

## 10. `or_else`

`or_else` is not ordinary choice.

```text
primary:or_else(fallback)
```

It means:

```text
commit primary if a primary world exists

commit fallback only if primary is certifiably absent
```

A fallback is valid only under an absence proof. “Not immediately solved” is not enough.

Safe fallback rule:

```text
If primary or_else fallback commits a fallback world,
then no compatible primary world exists in the certified managed facts
used by that commit.
```

This is why `or_else` requires a world model. A preferred branch might be satisfiable only through:

```text
another root
a tensor-internal rendezvous
a resource observation
a source arrival
a retry after stale preparation
```

Fallback must not commit merely because the local proof did not find the preferred world quickly.

Important non-laws:

```text
or_else is not choice

or_else is not timeout

or_else is not local fallback

primary or_else fallback ≠ fallback or_else primary
```

`or_else` is preference under certified absence.

## 11. `wrap`

`wrap` is a post-commit continuation.

```text
wrap(op, k)
```

It must not affect which world can commit. It changes what happens after a world has been selected and committed.

Law:

```text
wrap(op, id) ≈ op
```

Conditional law:

```text
wrap(wrap(op, f), g) ≈ wrap(op, g ∘ f)
```

provided composition preserves multiple values and the callbacks are well behaved.

Core distinction:

```text
bind builds worlds
wrap observes committed worlds
```

Important non-law:

```text
wrap is not bind
```

`bind` can change the candidate world. `wrap` must not.

## 12. `guard`

`guard` is a search-phase option constructor. It allows an option to be constructed using attempt-local context.

It is intentionally not reduced to ordinary `bind`, because guard evaluation is part of proof construction and may have attempt-level caching or context-sensitive behaviour.

Guard callbacks must obey search-phase discipline:

```text
pure
non-suspending
no external mutation
no irreversible effects
```

A guard callback may inspect the proof context made available by the runtime, but any fact that should influence readiness or absence must be represented through resources or sources.

## 13. Nacks

A nack is an obligation associated with a branch that was made eligible but did not win.

Informally:

```text
with_nack(make, op)
```

means:

```text
construct a losing-branch obligation
try op
if the branch loses after becoming eligible, discharge the nack
```

Nacks are useful for cancellation-like protocols and losing-branch cleanup, but they are subtle because they sit near the boundary between search and post-decision behaviour.

Expected discipline:

```text
nack construction is search-phase code
nack discharge is post-decision code
nack discharge must not affect the committed world
nack errors must have an explicit policy
```

A desirable law:

```text
A nack belonging to a branch is discharged iff that branch became eligible
for selection and did not commit.
```

If the implementation silently ignores errors in losing nack callbacks, that must be treated as an explicit runtime policy, not an algebraic fact.

Longer term, nacks may be better represented as typed losing effects. Until then, they should remain primitive rather than derived through `bind`, because the solver must be able to see losing-branch obligations without running arbitrary branch continuations.

## 14. Resources

Resources provide transactional truth.

A resource kind should define some or all of:

```text
clone      create a speculative view
propose    create a journal from an option
merge      combine compatible journals
prepare    validate a journal against current state
apply      commit a prepared journal
absence    certify absence under observed managed facts
observe    report interests that may change readiness
```

Resource soundness obligations:

```text
Rollback:
  losing worlds do not apply journals.

Merge soundness:
  if two journals merge, the merged journal represents both intentions
  atomically.

Conflict refusal:
  incompatible journals reject the candidate world.

Stale refusal:
  a journal prepared against stale state must not be applied.

Absence conservatism:
  absence may be reported only when no matching world can become available
  without a new observation.
```

Resource authors must be conservative. Incorrect absence breaks `or_else`.

## 15. Sources and managed validity

Sources represent external arrivals.

A source contributes:

```text
managed facts   what search can observe, such as queue head or readiness level
arrivals        events available through those managed facts
interests       what the host should wait for
```

Source law:

```text
No false absence:
  if a source/resource fact is used to certify absence,
  any later arrival that could make the preferred branch available
  must bump that fact's stamp so a saved proof fails pull validation.
```

Runtime blockedness depends on truthful sources:

```text
If the runtime reports blocked interests I, then a future committed world
requires at least one interest in I to change, unless a host violates the
source contract.
```

## 16. Effects

Effects are post-commit runtime obligations.

Examples:

```text
wake
spawn
interrupt
lifetime event
host obligation
```

Effects are not speculative. A candidate world may contain effects, but they are not discharged unless the world commits.

Effect laws:

```text
No speculative effects:
  effects from losing worlds are never discharged.

Effect merge:
  effects with distinct keys may coexist.

Effect conflict:
  effects with the same key must merge according to their effect kind,
  or reject the candidate world.

Post-commit discharge:
  effects discharge only after resource journals commit.
```

Effect keys must be stable. Effect kinds should use string, number or other stable key values. Identity-like keys derived from arbitrary tables should be avoided unless identity is the intended semantics.

## 17. Regions, tasks and ownership

Regions make responsibility transactional.

The ownership state may be thought of as a resource:

```text
ownership graph Ω
```

Options propose ownership journals:

```text
admit(task, region)
handoff(task, from, to)
release(task)
seal(region)
settle(region)
```

Ownership laws:

```text
Unique ownership:
  a live owned claim has at most one owner.

Atomic handoff:
  ownership leaves the source and enters the target in the same committed world.

No lost responsibility:
  a claim cannot disappear except through release, settlement, or transfer.

Settlement soundness:
  a region may report settled only when all claims in its subtree are settled,
  released, or transferred according to policy.
```

This is one of the central ways Fibres extends transactional events. Ownership transfer is not procedural aftermath; it is part of the committed world.

## 18. Host boundary

Hosts do not decide the algebra. Hosts provide truthful blocking and arrivals.

A host must preserve:

```text
readiness accuracy
arrival delivery
timer delivery
fd/handle deregistration
wake delivery
managed fact stamping
serialisation into the runtime
```

The kernel reports wait interests. The host decides how to block for those interests.

Host law:

```text
Host adequacy:
  if the host reports an arrival or readiness event, the corresponding managed
  source fact must be updated through its capability so blocked options are
  retried and saved absence proofs are invalidated by stamp validation.
```

Host bugs can break algebraic guarantees by lying about the external world.

## 19. Runtime transactions are not durable transactions

Fibres transactions are runtime transactions.

They are not:

```text
database transactions
crash-durable logs
distributed consensus
persistent message queues
```

The guarantee is:

```text
within one runtime commit, selected journals/effects/ownership changes are
coherent and losing worlds do not partially apply
```

Durability must be implemented as a resource/effect discipline on top of the runtime, not assumed from the option algebra itself.

## 20. Expected laws

This section collects useful laws. Some are unconditional; others require purity, stable resources, or scheduler-insensitive observation.

### Always and bind

```text
always(v):and_then(k) ≈ k(v)

op:and_then(always) ≈ op
  where always means λx. Op.always(x)

op:map(f) ≈ op:and_then(λx. always(f(x)))
```

Conditional on pure callbacks.

### Choice

```text
choice() ≈ never

choice(never, op) ≈ op

choice(op, never) ≈ op

choice(choice(a, b), c) ≈ choice(a, b, c)
```

Not generally commutative if scheduler order is observable.

### Product

```text
all({}) ≈ always(empty_rows)

tensor({}) ≈ always(empty_rows)

all({op}) ≈ op, modulo row packaging

tensor({op}) ≈ op, modulo row packaging
```

Conditional:

```text
all(lanes) ≈ tensor(lanes)
  only when no internal rendezvous is possible or required
```

### Or else

```text
available(primary) ⇒ primary:or_else(fallback) commits primary

absent(primary) ⇒ primary:or_else(fallback) may try fallback

unknown(primary) ⇒ primary:or_else(fallback) must not treat primary as absent
```

Important non-law:

```text
primary:or_else(fallback) ≠ choice(primary, fallback)
```

### Wrap

```text
wrap(op, id) ≈ op

wrap(wrap(op, f), g) ≈ wrap(op, g ∘ f)
```

Conditional on post-commit callback discipline.

### Effects

```text
effects(losing_world) are not discharged

effects(committed_world) discharge after resource commit
```

### Resources

```text
journals(losing_world) are not applied

stale prepare rejects or retries

merge conflict rejects the candidate world
```

## 21. Important non-laws

These are deliberately not laws.

```text
choice is not necessarily commutative

or_else is not choice

or_else is not timeout

absence is not failure to solve quickly

all is not tensor

wrap is not bind

effects are not resource writes

runtime transactions are not durable storage transactions
```

Stating non-laws is part of the public contract. It prevents appealing but false simplifications.

## 22. Completeness status

The algebra is substantially complete in shape.

It has coherent answers for:

```text
rendezvous
transactional resources
internal-world products
certified fallback
ownership handoff
post-commit effects
managed source facts
structured lifetime
stream/flow safety
```

The remaining work is chiefly contractual:

```text
fairness policy
solver budget and unknown outcome semantics
resource-author law tests
nack error policy
settlement failure policy
host backend law coverage
diagnostics for malformed yields or phase violations
```

The next step is not to add more cleverness. It is to protect the algebra by naming the laws, testing them, and making extension points conservative.

## 23. Summary

A Fibres option is a proof search for a compatible committed world.

```text
tensor composes proofs into one world

or_else requires proof of absence of the preferred world

resources provide transactional truth

sources provide managed observed facts

effects are obligations of committed worlds

regions make responsibility part of the world

wrap observes commit; bind constructs worlds
```

That is the heart of the system.
