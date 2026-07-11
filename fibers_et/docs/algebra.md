# The Fibres Algebra

This document describes the algebraic model underlying Fibres options.

The implementation is inspired by Concurrent ML, Software Transactional Memory, and Transactional Events, but the object being transacted here is broader than a memory update or a communication event. A Fibres option denotes a set of possible committed worlds. A world may contain synchronous rendezvous, transactional resource journals, externally-fed resource observations, ownership changes, and post-commit runtime effects.

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
journals        tentative resource state changes
observations    managed facts used during proof and validation
consequences    runtime obligations entailed by commit
wraps           per-participant post-commit value continuations
```

The runtime searches for a compatible world. If one is selected, it commits the world atomically with respect to the runtime state:

```text
search is speculative
commit is atomic
consequences are post-commit
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
  resource journals, ownership changes, external observations and
  post-commit consequences
```

The distinguishing move is that communication, state, ownership, external readiness and runtime obligations are not separate mechanisms. They are components of one committed world.

See [`comparison.md`](comparison.md) for a fuller comparison with CSP, CML, Transactional Events and Reagents.

## 3. Core option language

The public API exposes convenience forms, but proof search interprets seven
canonical term kinds:

```text
op ::=
    always(v...)
  | primitive(resource, request)
  | choose(op₁, ..., opₙ)
  | and_then(op, k)
  | product(mode, op₁, ..., opₙ)
  | or_else(primary, fallback)
  | consequence(commit_obligation)

mode ::= independent | interacting
```

Several public operators elaborate to these forms:

```text
never          ≜ choose()
map(op, f)     ≜ and_then(op, λxs. always(f(xs)))
guard(f)       ≜ and_then(always(), f), with attempt-local callback caching
all(ops)       ≜ product(independent, ops)
tensor(ops)    ≜ product(interacting, ops)
emit(c)        ≜ consequence(c)
```

Post-commit participant transforms (`wrap`) and typed defeat obligations
(`on_defeat`) are annotations on dynamic operation occurrences. They do not add
candidate-world constructors to the canonical search grammar.

## 4. Outcomes

Proof search has three semantic outcomes:

```text
Hit W
  A compatible candidate world W has been found.

Retry P
  No committing world exists through this path under the managed facts in P.
  P records validity frontiers and any host-actionable interests.

Unknown K
  Bounded or incomplete search has not established either Hit or Retry.
  K is a resumable search cursor or diagnostic reason.
```

The runtime may describe an uncaught `Retry` as pending or quiescent, but
blockedness is a scheduling interpretation rather than another semantic result.
Certified present absence is represented by `Retry`; there is no separate
`Absent` outcome.

The essential distinction is:

```text
Retry ≠ Unknown
```

Consequently:

```text
not found is not Retry
search-budget exhaustion is not Retry
resource conflict is not Retry
stale validation is not Retry
```

`or_else` may consume `Retry`. It must propagate `Unknown`.

## 5. Worlds and commit

A world is a structured candidate.

```text
World W =
  {
    result,
    rendezvous,
    journals,
    observations,
    fallback_evidence,
    consequences,
    wraps
  }
```

A runtime commit has the shape:

```text
current state Σ
candidate world W
prepared resource journals J
post-commit consequences C
result value v
```

Commit is valid only if:

```text
all rendezvous obligations are satisfied
all journals merge without conflict
all prepared resources are still valid
all consequence keys merge or are distinct
all ownership changes preserve region invariants
all fallback Retry evidence remains valid
```

Commit then proceeds conceptually as:

```text
1. prepare resource journals
2. reject if stale or conflicting
3. apply journals
4. discharge selected commit and defeat consequences
5. resume selected fibres with raw values and post-commit transforms
6. apply wraps inside each resumed fibre's `perform`
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
no dependence on facts not represented as resource observations
```

Search-phase callbacks include:

```text
and_then / and_then continuations
map callbacks, as derived and_then continuations
guard callbacks
resource proposal and resolver functions
```

Search callbacks are proof code, not effect code.

### Commit phase

Commit phase applies one selected world.

Post-commit callbacks and obligations include:

```text
wrap callbacks
effect discharge
selected fibre resumption
scope boundary facts
host wake/spawn/interrupt obligations
```

A callback that must observe the committed world belongs in `wrap`, not in `map` or `and_then`.

## 7. `and_then` and derived `map`

`and_then` extends a proof using the value of a prior proof.

```text
and_then(op, k)
```

If `op` proves a value `v`, then `k(v)` produces the next option in the same search.

`map` is derived:

```text
map(op, f) ≜ and_then(op, λv. always(f(v)))
```

This gives the usual functor behaviour under purity:

```text
map(id, op) ≈ op

map(g, map(f, op)) ≈ map(g ∘ f, op)
```

These are conditional laws. They require `f` and `g` to be pure search-phase functions.

`and_then` is more powerful than `map`: it can use a value to choose the next option and therefore change the candidate world.

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
product(mode, lanes)
```

The public operators are:

```text
all(lanes)
  ≜ product(independent, lanes)

tensor(lanes)
  ≜ product(interacting, lanes)
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
  request:offer_op(session, supervisor),
  supervisor:accept_op(),
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

### Allocation and handoff

For resource premises, the distinction is best understood as allocation versus
handoff.

`all` may coordinate competing demands over shared stock. Its lanes still commit
as one all-or-nothing product, so a resource resolver may allocate distinct
pre-existing facts to different lanes. For example, two ordered-pop lanes may
consume two different entries from the same committed index, and two counter
take lanes may consume two different permits from the same committed counter.

`all` may also let sibling lanes constrain one another. If one lane removes an
entry, another ordered-pop lane must not select that removed entry, because the
combined world would not be coherent.

`all` must not let one lane positively supply the fact that makes another lane
satisfiable. That is handoff, and belongs to `tensor`.

```lua
-- Allocation from shared committed stock: allowed for all and tensor.
Op.all({
  ix:pop_first_op(),
  ix:pop_first_op(),
})

-- Constraint from a sibling lane: allowed for all and tensor.
Op.all({
  ix:remove_op("a"),
  ix:pop_first_op(), -- must skip a
})

-- Handoff from sibling supply: tensor only.
Op.tensor({
  ix:insert_op("z", 0, "Z"),
  ix:pop_first_op(), -- may receive z
})

-- Under all, the pop lane is not independently satisfiable from the insert.
Op.all({
  ix:insert_op("z", 0, "Z"),
  ix:pop_first_op():or_else(Op.always("empty")),
})
-- commits the insert and returns "empty" for the pop lane.

-- The same law applies to counters. From c = 2, this may allocate two permits.
Op.all({
  c:take_op(1),
  c:take_op(1),
})

-- From c = 0, tensor may hand off a sibling give to a take.
Op.tensor({
  c:give_op(1),
  c:take_op(1),
})

-- From c = 0, all may not use the sibling give as positive supply.
Op.all({
  c:give_op(1),
  c:take_op(1):or_else(Op.always("none")),
})
-- commits the give and returns "none" for the take lane.

-- A queue built from Index + Counter inherits the same law.
Op.tensor({ q:put_op("x"), q:get_op() }) -- get may receive x
Op.all({ q:put_op("x"), q:get_op():or_else(Op.always("empty")) })
-- commits the put and returns "empty" for the get lane.
```

In short:

```text
all    permits shared allocation and sibling constraints
tensor additionally permits sibling-to-sibling positive supply
```

## 10. `or_else`

`or_else` is not ordinary choice.

```text
primary:or_else(fallback)
```

It means:

```text
commit primary if a primary world exists

commit fallback only if primary returns a valid Retry proof
```

A fallback is valid only under a proof-carrying `Retry`. “Not immediately solved” is not enough.

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
an external feed delivery
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

`or_else` is preference under proof-carrying retry.

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
and_then builds worlds
wrap observes committed worlds
```

Important non-law:

```text
wrap is not and_then
```

`and_then` can change the candidate world. `wrap` must not.

## 12. `guard`

`guard` is delayed transaction construction. Formally it elaborates to an `and_then`
from `always()`. The implementation retains an attempt-local cache key and passes
the proof callback context, preserving the rule that one guard occurrence is
evaluated at most once per perform attempt even when search backtracks.

Guard callbacks obey the same search-phase discipline as `and_then` and `map`:

```text
pure
non-suspending
no external mutation
no irreversible effects
```

Any mutable fact that influences readiness or retry must be observed through a
resource frontier.

## 13. Defeat consequences

A typed defeat consequence is attached to a dynamic operation occurrence:

```text
on_defeat(op, obligation)
```

It is dispatched when that occurrence was entered as a competing alternative
and another incompatible alternative commits. The carrier is the operation
occurrence, not each candidate world generated through it, so one occurrence can
be defeated at most once.

These events are not defeat:

```text
search backtracking
validation conflict
Retry
Unknown
primary Retry followed by an or_else fallback
an unentered branch
```

A selected occurrence discards its defeat obligations. An entered losing
competitor dispatches them as typed runtime effects before participants resume.
Products contain collaborators, not competitors: sibling lanes do not defeat
one another. An enclosing choice may defeat the product occurrence as a whole.

Event-shaped negative acknowledgement is therefore a derived advanced pattern:
a defeat consequence may publish a one-shot externally-fed resource fact which another
operation observes. It is not primitive syntax.

## 14. Resources

Resources provide transactional truth.

A resource kind should define some or all of:

```text
clone      create a speculative view
propose    create a journal from a primitive request
merge      combine compatible journals
resolve    exhaustively solve open resource premises
retry      return a proof observing the facts that justify no solution
prepare    validate a selected journal against current state
apply      commit a prepared journal
interest   describe host action that may change an observed fact
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

Retry conservatism:
  Retry may be returned only when no matching world can become available
  without changing a recorded frontier.
```

Resource authors must be conservative. An unjustified Retry breaks `or_else`.

## 15. Externally-fed resources and managed validity

External arrival is not a separate semantic category. A signal, event queue,
readiness level or clock is an ordinary transactional resource whose committed
state may also be changed through a runtime-bound `ExternalFeed` capability.

Such a resource contributes:

```text
managed facts   what search observes, such as queue head or readiness level
frontiers       generation-stamped validity evidence
interests       what the host may await when an uncaught Retry reaches it
feed            authority to deliver an external state change
```

External-feed law:

```text
No false Retry:
  if an externally-fed resource fact justifies Retry, every delivery that could
  make the operation ready must invalidate the recorded frontier before search
  is resumed.
```

Interests are actionable descriptions, not proof. The frontiers in a
`RetryProof` justify the conclusion; timer and readiness interests merely tell
the host how one of those facts may change.

## 16. Effects

Effects are post-commit runtime obligations.

Examples:

```text
wake
spawn
interrupt
boundary fact
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
move(task, from, to)
release(task)
seal(region)
settle(region)
```

Ownership laws:

```text
Unique ownership:
  a live owned claim has at most one owner.

Atomic movement:
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

The kernel reports retry interests. The host decides how to block for those interests.

Host law:

```text
Host adequacy:
  if the host reports an arrival or readiness event, the corresponding managed
  externally-fed resource fact must be updated through its capability so retrying operations are retried and saved retry proofs are invalidated by stamp validation.
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

### Always and sequencing

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
Hit(primary) ⇒ primary:or_else(fallback) commits primary

Retry(primary, P) ⇒ primary:or_else(fallback) may search fallback under P

Unknown(primary) ⇒ primary:or_else(fallback) propagates Unknown
```

Important non-law:

```text
primary:or_else(fallback) ≠ choose(primary, fallback)
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

Retry is not failure to solve quickly

all is not tensor

wrap is not and_then

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
proof-carrying fallback
ownership movement
post-commit effects
managed externally-fed resource facts
structured scope
stream/flow safety
```

The remaining work is chiefly contractual:

```text
fairness policy
solver budget and Unknown cursor semantics
resource-author law tests
defeat-consequence error policy
settlement failure policy
host backend law coverage
diagnostics for malformed yields or phase violations
```

The next step is not to add more cleverness. It is to protect the algebra by naming the laws, testing them, and making extension points conservative.

## 23. Summary

A Fibres option is a proof search for a compatible committed world.

```text
tensor composes proofs into one world

or_else requires a valid Retry proof for the preferred operation

resources provide transactional truth

external feeds update managed resource facts

effects are obligations of committed worlds

regions make responsibility part of the world

wrap observes commit; and_then constructs worlds
```

That is the heart of the system.
