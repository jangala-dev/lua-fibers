# Eventful Transactions algebra laws

This note records the intended algebraic laws for the current `et_fibers`
core.  It is written as a contract for adversarial tests, not as a complete
formal semantics.

The notation below uses `a`, `b`, and `c` for operations; `k` for callbacks
that return operations; `f` and `g` for raw-value functions; `p` for
post-commit callbacks; `r` for resources; and `q` for resource requests.

## 1. Global phase laws

The algebra has distinct phases.

```text
construction
  Lua values for operations are built.

proof expansion and search
  operations elaborate into proof frames, ports, fragments, obligations,
  settlement identities, and post-commit programs.

validation and commit preparation
  a closed proof is checked for resource, preference, and settlement validity.

commit application
  resource fragments are installed, settlements are applied, and commit
  descriptors are emitted.

post-commit resumption
  fibres resume and post-commit value programs run.
```

The core phase laws are:

```text
Construction is inert.
  Building an Op must not perform resource actions, settle nack cells, emit
  commit descriptors, or resume fibres.

Proof search is not an effect.
  Search may construct possible worlds. It must not publish settlements,
  commit resources, emit descriptors, spawn fibres, or resume participants.

Commit is the irreversible boundary.
  Resource installation, settlement application, and descriptor emission occur
  only after a world has been selected and prepared.

Post-commit code cannot roll back.
  wrap callbacks and resumed fibre code run after commit. They may fail or run
  fresh transactions, but cannot change which world committed.
```

Callbacks used during proof construction are subject to the proof-construction
contract. They may construct and return operations, but must not call
`Op.perform`, spawn fibres, or mutate transactional resources directly.

Lua cannot enforce purity of arbitrary functions. The laws below therefore
apply to well-behaved callbacks and resources.

## 2. Values, evidence, and post programs

Each operation has two value layers.

```text
raw transactional value
  visible to bind, map, product joins, resource fragments, cuts, and
  preference judgements before commit.

post-commit value program
  run only after the world has committed, inside the resumed fibre.
```

A closed world carries evidence:

```text
resource fragments
commit descriptors
pre-commit obligations
selected settlement refs
post-commit value programs
participant resumptions
```

Evidence contributed by losing branches is discarded.

## 3. `Op.always(...)`

`Op.always(...)` immediately contributes a closed proof frame with the supplied
raw values and no additional evidence.

Laws:

```text
always(x) has raw value x.
always() has no raw values.
always(...) contributes no ports, fragments, descriptors, obligations,
settlements, or post programs.
```

Identity laws for well-behaved callbacks:

```text
always(x):and_then(k)  ==  k(x)
always(x):map(f)       ==  always(f(x))
always(x):wrap(p)      commits as always(x), then returns p(x)
```

`always` is a successful operation; it is not a commit by itself. It commits
only when the surrounding performed world commits.

## 4. `Op.never()`

`Op.never()` contributes no proof frames.

Laws:

```text
never():and_then(k)  ==  never()
never():map(f)       ==  never()
never():wrap(p)      ==  never()
choice(never(), a)   ==  a
choice(a, never())   ==  a
all({ ..., never(), ... })    ==  never()
tensor({ ..., never(), ... }) ==  never()
```

For preferential choice:

```text
never():or_else(b) may use b, because the primary branch is absent.
```

Absence means absence proved by the search and preference judgement machinery,
not merely failure within a fuel budget.

## 5. `op:choice(other)` and `Op.choice(...)`

`choice` forms nondeterministic alternatives. Each branch is expanded as a
possible world. Exactly one branch contributes evidence to the committed world.

Laws:

```text
choice(a, b) contributes worlds from a and worlds from b.
Losing branch evidence is discarded.
Losing branch fragments are discarded.
Losing branch descriptors are discarded.
Losing branch post programs are discarded.
Losing branch selected-settlement evidence is discarded.
```

Unit and associativity laws, up to search order:

```text
choice(a, never()) == a
choice(never(), a) == a
choice(choice(a, b), c) == choice(a, choice(b, c))
```

Commutativity is semantic but not operational:

```text
choice(a, b) and choice(b, a) describe the same set of possible worlds,
but may search them in a different order.
```

Settlement law:

```text
A protected occurrence in a retained live branch may become lost if the same
RootAttempt resolves through another retained branch.
A merely speculative branch is not published and therefore is not lost.
```

## 6. `op:or_else(fallback)`

`or_else` is preferential choice. The fallback branch is committable only if the
runtime proves absence of a better committable primary world under the same
stable generation and decision prefix.

Laws:

```text
a:or_else(b) first admits primary worlds from a.
Fallback worlds from b carry a pre-commit absence obligation.
The obligation asks whether a better primary world is committable, not merely
whether a primary proof can close syntactically.
```

Tri-valued judgement law:

```text
found   => fallback is not committable
absent  => fallback may be committable
budget  => fallback is not committable; budget is not absence
```

Function fallback law:

```lua
a:or_else(function() return b end)
```

is normalised through `Op.guard`, so the fallback constructor is memoised for
the root attempt, proof address, and decision prefix.

Speculation law:

```text
Exploring a primary branch while checking fallback absence must not publish
settlements, emit descriptors, or mutate resources.
```

## 7. `op:and_then(k)`

`and_then` is transactional dependent sequencing.

It does not mean “commit `op`, then run `k`”. It means:

```text
prove op tentatively;
when its raw value is known, run k(raw_value) during proof reduction;
expand the returned operation;
commit the whole resulting world or none of it.
```

Laws for well-behaved callbacks:

```text
always(x):and_then(k) == k(x)
never():and_then(k)   == never()
```

Associativity:

```lua
op:and_then(k):and_then(h)
```

is equivalent to:

```lua
op:and_then(function(x)
  return k(x):and_then(h)
end)
```

Phase law:

```text
k runs during proof reduction, not at construction time and not after commit.
k must return an Op or boundary operation.
k must not call Op.perform or spawn.
```

Boundary law:

```text
It is illegal to transactionally sequence after a wrap boundary.
```

So this is rejected:

```lua
op:wrap(p):and_then(k)
```

because `p` runs after the transaction has already committed.

## 8. `op:map(f)`

`map` is transactional raw-value transformation.

Laws for pure `f` and `g`:

```text
always(x):map(f) == always(f(x))
never():map(f)   == never()
op:map(id)       == op
op:map(f):map(g) == op:map(function(x) return g(f(x)) end)
```

Relationship to bind:

```lua
op:map(f)
```

is semantically:

```lua
op:and_then(function(x) return Op.always(f(x)) end)
```

but `map` returns a raw value, not an operation.

Phase law:

```text
f runs during proof reduction.
f must be pure for transaction purposes.
f must not call Op.perform, spawn, mutate resources, publish settlements, or
emit descriptors directly.
```

Boundary law:

```text
It is illegal to map transactionally after a wrap boundary.
```

## 9. `op:wrap(p)`

`wrap` attaches a participant-local post-commit value continuation.

It is not a transaction consequence and not a commit descriptor.

Laws:

```text
wrap does not change the raw transactional value.
wrap does not affect proof selection, resource validation, or rendezvous.
wrap runs only after the world commits.
If the operation loses or aborts, its wrap does not run.
```

Composition law:

```lua
op:wrap(f):wrap(g)
```

returns the same committed world as `op`, and after commit returns:

```lua
g(f(raw_value))
```

Phase law:

```text
p may call Op.perform and may perform ordinary post-commit work.
Failure in p is a post-commit fibre failure, not a transaction abort.
```

Boundary law:

```text
wrap marks a post-commit boundary. Transactional and_then/map may not be
attached after it.
```

## 10. `Op.guard(f)`

`guard` is delayed, attempt-local proof expansion.

Laws:

```text
Op.guard(f) does not run f at Lua construction time.
f runs when the guard occurrence is reached during proof expansion.
f must return an Op or boundary operation.
guard contributes no evidence of its own.
The operation returned by f contributes ordinary evidence.
```

Memoisation law:

```text
For a given RootAttempt, proof address, and decision prefix, f runs at most
once. Proof-search replay reuses the same returned operation.
```

New-attempt law:

```text
A fresh perform attempt may run f again.
```

Phase law:

```text
f runs under proof construction.
f must not call Op.perform, spawn, commit, publish, settle, or mutate
transactional resources directly.
```

Hygiene law:

```text
guard has no settlement meaning.
guard uses proof-expansion identity, not settlement occurrence identity.
```

Equations for phase-pure `f`:

```lua
Op.guard(function() return op end):and_then(k)
```

is equivalent to:

```lua
Op.guard(function() return op:and_then(k) end)
```

and similarly for `map` and `wrap`, subject to the usual phase restrictions.

## 11. `Op.with_nack(f)`

`with_nack` protects an occurrence and gives the callback an ordinary nack
operation observing that occurrence's settlement.

Laws:

```text
Op.with_nack(f) does not run f at construction time.
f runs during proof expansion when the protected occurrence is reached.
f receives nack :: Op.
f must return the protected Op.
```

Settlement identity law:

```text
with_nack creates or reuses a SettlementRef for:
  RootAttempt
  proof address
  decision prefix
  parent settlement, if any
```

Selected evidence law:

```text
Every closed world whose proof passes through the protected body carries
selected-settlement evidence for this occurrence.
No other world carries that selected-settlement evidence.
```

Publication law:

```text
Publication is not expansion.
The runtime publishes only settlement refs found in the retained parked
frontier of a RootAttempt.
Speculative proof search must not publish settlements merely by seeing them.
```

Selection versus publication:

```text
A world may select an unpublished settlement ref.
Only a published pending ref can later become lost or withdrawn.
```

Lost law:

```text
lost is resolved-attempt non-selection, not global non-selection.
A published ref becomes lost only when its own RootAttempt resolves through a
world that does not select that occurrence.
Unrelated commits do not settle it.
```

Withdrawal law:

```text
If a live RootAttempt is withdrawn, its published pending refs become
withdrawn.
```

Nack enablement law:

```text
pending    => nack cannot close
selected   => nack cannot close
lost       => nack can close
withdrawn  => nack can close
```

Prior-terminal law:

```text
nack observes only prior terminal settlement. It cannot close in the same
CommitPlan that would make the protected occurrence lost.
```

So this must not commit in one plan:

```lua
Op.with_nack(function(nack)
  return protected:or_else(nack)
end)
```

Nested law:

```text
child selected requires parent selected.
parent lost or withdrawn prevents child selected.
A published child whose parent is withdrawn should be treated as withdrawn,
not independently lost.
```

Hygiene law:

```text
with_nack is settlement-aware proof expansion.
It must not be implemented as a channel offer, a live-port flag, a wrap, or a
commit descriptor.
```

## 12. Internal `nack` operation

The internal nack operation is received only through `with_nack`.

Laws:

```text
nack is an ordinary Op.
nack contributes a unary settlement-wait frame.
nack closes only when the associated settlement cell is already lost or
withdrawn.
nack never closes for pending or selected.
```

Product law:

```text
A nack frame inside all/tensor reduces in its original product lane; reduction
must not escape the product box or lose lane metadata.
```

## 13. `Op.request(resource, request)`

`request` exposes a rendezvous-style resource port.

Laws:

```text
request contributes an open wait frame.
The frame closes only by a compatible cut with another request frame.
A cut is accepted only if resource:try_match(request_a, request_b) succeeds.
The resource responses contribute raw values and evidence to the matched
participants.
```

No-speculative-mutation law:

```text
try_match may describe compatibility and responses; it must not commit
resource state or perform irreversible effects.
```

Choice law:

```text
Requests in losing branches are discarded.
```

Product law:

```text
request ports in sibling tensor lanes may cut with each other.
request ports in sibling all lanes may not cut with each other.
```

## 14. `Op.access(resource, request)`

`access` performs a local transactional resource step.

Laws:

```text
access does not mutate the resource during proof search.
It accumulates or transforms a local resource fragment.
The returned raw value is taken from the resource's fragment step response.
The fragment is installed only if the whole world commits.
```

Fragment laws expected from a resource:

```text
empty_fragment() is the fragment identity.
step_fragment or step_fragment_with_view is speculative and side-effect-free.
merge_fragments is associative where compatible.
validate_fragment checks that the fragment is still committable.
prepare_commit_fragment may prepare an installation plan but must not mutate.
commit_fragment installs after preparation succeeds.
```

Product context law:

```text
A product lane reads inherited base evidence plus lane-local delta.
A lane contributes only its local delta.
The product base is merged once for the product, not once per lane.
```

Abort law:

```text
Fragments from losing branches, failed products, or aborted worlds are
discarded.
```

## 15. `Op.emit(event)`

`emit` records a commit descriptor.

Laws:

```text
emit contributes no raw values.
emit contributes a commit descriptor to the selected world.
The descriptor is interpreted only if the selected world commits.
Descriptors from losing branches are discarded.
```

Ordering law:

```text
Resource commits and settlement updates happen before descriptor emission.
Descriptor emission happens before participant resumption and wrap execution
observe return.
```

Descriptor discipline:

```text
Commit descriptors should be runtime-interpreted, bounded, and not influence
transaction selection.
```

In the prototype this is a contract rather than a full type-system guarantee.

## 16. `Op.tensor({ ... })`

`tensor` is product composition whose sibling lanes may internally synchronise.

Laws:

```text
tensor({}) returns a single raw table value {}.
tensor({ a, b, ... }) commits only when every lane contributes a compatible
world.
The raw value is product-shaped: one lane value per child.
```

Internal-cut law:

```text
Sibling lanes inside the same tensor box may rendezvous with each other.
```

Evidence law:

```text
product base evidence is merged once.
each lane contributes lane-local evidence.
post programs remain product-shaped.
```

Failure law:

```text
If any lane has no compatible proof, the tensor branch has no proof.
```

Boundary law:

```text
If a lane contains a wrap, the tensor may still commit, but transactional
and_then/map cannot be attached after a boundary-tainted product.
```

Settlement law:

```text
with_nack inside a tensor lane selects or waits within that lane. Nack
reduction must preserve the tensor box and lane identity.
```

## 17. `Op.all({ ... })`

`all` is product composition whose sibling lanes are independent for
rendezvous purposes.

Laws:

```text
all({}) returns a single raw table value {}.
all({ a, b, ... }) commits only when every lane contributes a compatible world.
The raw value is product-shaped: one lane value per child.
```

No-internal-cut law:

```text
Sibling lanes inside the same all box may not rendezvous with each other.
```

Otherwise `all` shares the product laws of `tensor`:

```text
product base evidence is merged once;
each lane contributes lane-local evidence;
post programs remain product-shaped;
fragments from failed lanes are discarded;
with_nack/nack inside a lane preserve the all box and lane identity.
```

Operational distinction:

```lua
Op.tensor({ ch:put('x'), ch:get() }) -- may close internally
Op.all({ ch:put('x'), ch:get() })    -- must not close by self-rendezvous
```

## 18. `Op.perform(op)`

`perform` is the runtime boundary. It parks the current fibre with a root
attempt, asks the runtime to find a committable world, commits that world, and
resumes the participant with post-commit values.

Laws:

```text
perform may not be called during proof construction.
perform creates a RootAttempt.
The attempt may be parked, resolved by commit, or withdrawn.
The returned Lua values are post-commit values, not necessarily raw proof
values.
```

Commit ordering law:

```text
validate and prepare world
commit resource fragments
apply settlement updates
bump generation
emit commit descriptors
resume participants with post-commit frames
run post-commit value programs inside resumed fibres
```

Failure law:

```text
If no committable world can be found, the task remains parked unless the
runtime determines deadlock or the attempt is withdrawn.
```

Fresh-attempt law:

```text
Memoised guard and with_nack callback results are per RootAttempt. A later
perform attempt may re-run them and allocate fresh attempt-local identities.
```

## 19. Resource laws

Resources used with `request` or `access` must obey the transaction contract.

Rendezvous resources:

```text
try_match(a, b) is speculative.
try_match is symmetric where the resource semantics says it is symmetric.
Successful matches return response evidence for both sides.
try_match must not mutate committed resource state.
```

Local transactional resources:

```text
fragment steps are speculative;
fragment merge is deterministic for compatible fragments;
validation does not mutate;
prepare does not mutate;
commit installs only a prepared valid fragment;
commit must not fail after preparation succeeds, except by violating the
resource contract.
```

Commit-descriptor resources:

```text
descriptors are interpreted after resource commit and settlement application.
Descriptors must not affect which world is selected.
```

## 20. Adversarial testing checklist

Adversarial tests should try to falsify these boundaries.

```text
construction-time effects
  guard and with_nack callbacks must not run at construction.

proof-search effects
  speculative branches must not publish settlements, emit descriptors, or
  mutate resources.

memoisation
  guard and with_nack callbacks must not drift across proof replay, but should
  run again for a fresh RootAttempt.

preference
  budget is not absence; dominated primary candidates do not validate fallback;
  forced decision paths are stable.

settlement
  selected is not publication; lost is not global non-selection; unrelated
  commits do not fire nacks; nacks observe only prior terminal states.

products
  tensor allows sibling cuts; all forbids them; lane evidence and nack
  reduction must preserve product identity.

boundaries
  transactional bind/map cannot cross wrap; wrap failure cannot abort commit;
  post-commit perform is allowed.

resources
  losing branch fragments vanish; product base evidence is merged once;
  prepare/apply split is observationally silent before apply.
```

## 21. Short normative summary

The algebra is lawful when these three principles remain intact:

```text
proof search is not an effect;
commit is the only irreversible boundary;
post-commit continuations are not transaction consequences.
```

`guard` and `with_nack` are the operators most likely to blur those lines.
`guard` must remain proof-only. `with_nack` may introduce settlement identity,
but publication and settlement must remain runtime acts tied to parked and
resolved RootAttempts.
