# The Fibers option algebra

Public examples use `local Op = require('fibers.op')`; the contextual `fibers` module supplies `perform`, not option constructors.

This document states the semantic model implemented by `fibers`. It is not a complete formalisation, but it defines the distinctions which implementations and trusted facilities must preserve.

## 1. Transactions describe worlds

An option is inert. It denotes possible committed worlds rather than performing an action immediately.

`Op` can be thought of as an **option**: an inert alternative constructed by an `_op` method and combined before `perform`.

```text
option  ≈ a search problem for compatible committed worlds
runtime    ≈ search, validate, commit, discharge, resume
```

A successful world may contain:

```text
participant results
synchronous exchange matches
versioned-location deltas
custody changes
observations and negative guards
commit and defeat effects
participant-local wraps
```

Search is speculative. Losing worlds install no state and discharge no effects.

Options are opaque library values, not a hostile-code immutability boundary.
Application and facility code should construct and combine them through the
public API rather than altering their table representation. The runtime protects
its managed stores and validates supported operations, but deliberately does not
attempt to prevent trusted Lua code from using raw or debug access.

Named map forms use string keys so that ordering is portable and deterministic.
Use ordered `{ name, option }` entries when a non-string label is required.

## 2. Canonical option language

The public API elaborates to seven canonical forms:

```text
option ::=
    always(values)
  | primitive(programme)
  | choice(option₁, ..., optionₙ)
  | and_then(option, continuation)
  | product(mode, option₁, ..., optionₙ)
  | or_else(primary, fallback)
  | consequence(effect)

mode ::= independent | interacting
```

Derived forms include:

```text
never          = choice()
map(option, f) = and_then(option, values -> always(f(values)))
guard(f)       = activation-local delayed construction
all(lanes)     = product(independent, lanes)
tensor(lanes)  = product(interacting, lanes)
emit(effect)   selects a typed post-commit consequence
```

`wrap` and `on_defeat` annotate dynamic occurrences. They do not add new candidate-world constructors.

## 3. Search outcomes

The semantic outcomes are:

```text
Hit W
  A compatible candidate world W has been found.

Retry P
  The relevant search scope has been exhaustively refuted under managed facts P.
  P records negative validation checks and any host-actionable interests.

Unknown
  Bounded search has not established Hit or Retry.
```

The essential distinction is:

```text
Retry ≠ Unknown
```

Consequently:

```text
failure to find a world quickly is not Retry
search-budget exhaustion is not Retry
one rejected candidate is not Retry
validation conflict is not Retry
one exhausted primitive query is not necessarily Retry
```

The production ledger machine retains its explicit alternative stack when a bounded search returns `Unknown`. A later bounded call resumes the same proof while its pending frontier, committed observations and external epoch remain unchanged. The copy-on-branch reference evaluator deliberately restarts and remains the semantic oracle.

## 4. Candidate proof and commit

A candidate may be viewed as:

```text
Candidate {
    participants
    packed results
    observed location versions
    combined location deltas
    negative guards from preferred-side refutations
    selected effects
    participant wrap trees
}
```

Commit is valid only while:

```text
all selected participants still wait on the same attempts
all observed versions remain current
all negative guards remain true
deltas remain mutually compatible
effects can be prepared as one batch
```

The commit sequence is:

```text
1. validate versions, attempts and negative guards
2. prepare the complete effect batch
3. install location deltas
4. discharge commit and defeat effects
5. resume selected fibres with raw packed results
6. run each participant's wraps inside its returning perform call
```

Effect discharge occurs after state installation. A discharge failure is fatal because the state commit cannot be rolled back.

## 5. Speculative callbacks and guard preparation

The following callbacks may be replayed while proof search explores candidate worlds:

```text
map and and_then callbacks
Machine transition callbacks
witness cursor factories and witness predicates
facility-specific state calculations
```

They must be deterministic for their explicit inputs, non-yielding, free of irreversible I/O and external mutation, and independent of undeclared transactional facts.

`guard` has a different lifetime. Its callback is evaluated once for each activated speculative progression and its returned `Op` is memoised for that activation. The callback receives a deliberately narrow ephemeral activation view. It exposes only one stable monotonic activation instant and the performing Scope:

```lua
Op.guard(function(activation)
  local started_at = activation:now()
  local scope = activation:scope()
  return explicit_residual_op(started_at, scope)
end)
```

The view is valid only while the builder runs. It does not expose the Runtime, host, Scope or internal activation label. It may be used to elaborate relative or contextual surface syntax into an explicit residual operation; retaining the view and consulting it later is an error. Guard preparation may allocate fresh private values or take an intentional activation-time snapshot, but it remains immediate and non-transactional: it must not yield, call `perform`, drive the runtime or mutate Fibers-managed transactional state outside an option. Its effects are not rolled back, and programs must not depend on the relative evaluation order of separate guard activations.

A callback which must observe a committed world belongs in `wrap` or an effect, not in `map`, `and_then`, `guard` or a primitive transducer.

## 6. Sequencing

`and_then` extends a speculative proof with the value of an earlier proof:

```text
option:and_then(k)
```

If `option` provisionally yields `v`, `k(v)` is entered in the same transaction and the same lane-local speculative view. If the continuation later fails, the earlier proof is retracted.

Conditional laws, assuming pure callbacks:

```text
always(v):and_then(k) ≈ k(v)

option:map(f) ≈ option:and_then(v -> always(f(v)))
```

`and_then` is not post-commit code. It may change the world which must be proved.

## 7. Choice

`choice(a, b, ...)` denotes unordered competing alternative occurrences. If several alternatives can form a committed world, source position gives none of them semantic priority. In this document, *unbiased* means absence of source-position priority; it does not mean statistical uniformity. Selection remains provisional until a complete world closes.

Expected laws for the set of admissible committed worlds are:

```text
choice() ≈ never
choice(never, option) ≈ option
choice(option, never) ≈ option
choice(choice(a, b), c) ≈ choice(a, b, c)
choice(a, b) ≈ choice(b, a)
```

The last law is about admissible outcomes, not probability or scheduling. The current evaluator traverses a seed-derived deterministic permutation. It does not promise uniform probability or fairness between perpetually available alternatives. Bounded search may still return `Unknown` before every branch has been resolved.

Alternative occurrences remain distinct. In particular, `on_defeat` attaches to an occurrence, so idempotence is not claimed:

```text
choice(a, a) need not be observationally equal to a
```

The evaluator may abandon any locally viable branch if it conflicts with the enclosing product or another selected participant. An application which requires preference should express it with `or_else`, not textual branch order.

## 8. Products, `all` and `tensor`

Both product modes:

```text
start each lane from the same parent speculative view
require every lane to complete
merge compatible lane deltas
commit as one world
preserve lane and nested result structure
```

### `all`

`all` requires independent satisfaction. A sibling change may constrain or invalidate another lane, but may not make an otherwise-unready lane ready.

### `tensor`

`tensor` additionally permits intentional sibling supply, including internal rendezvous and transactional hand-off.

The shared rule is:

```text
all sibling changes participate in final-world consistency
only tensor exposes compatible positive sibling supply
```

A sibling change is classified relative to a partial option:

```text
supplying     unready before, ready after
constraining  ready before, unready after
neutral       readiness unchanged
```

Under `all`, only positive supply is hidden. Constraining and neutral changes remain visible. Under `tensor`, compatible supply is visible.

Examples:

```lua
-- Joint allocation from committed stock.
Op.all({ counter:take_op(1), counter:take_op(1) })

-- Sibling deletion constrains the pop; the pop must skip the deleted entry.
Op.all({ index:remove_op('a'), index:pop_first_op() })

-- Sibling addition may supply a take only in tensor.
Op.tensor({ counter:give_op(1), counter:take_op(1) })

-- Sibling put may supply a get only in tensor.
Op.tensor({ keyed:put_op('k', 'v'), keyed:get_op('k') })
```

Product identities are represented as product rows:

```text
all({})    ≈ always(empty rows)
tensor({}) ≈ always(empty rows)
```

Singleton products are equivalent to their lane modulo row packaging.

## 9. `or_else`

```text
primary:or_else(fallback)
```

means:

```text
commit a primary world if one exists
otherwise search fallback only after primary yields Retry
```

The preferred search scope includes its option branches, primitive witnesses, compatible partners, recruited participants and dynamically constructed continuations.

A fallback candidate carries the preferred refutation's negative guards. It may commit only while those guards remain valid. If a signal arrives, a deadline matures, a location changes or a relevant participant appears, validation rejects the stale fallback and search restarts.

Important non-laws:

```text
or_else is not choice
or_else is not timeout
or_else is not an optional try-once probe
primary:or_else(fallback) is not commutative
```

`or_else` is proof-directed immediate fallback. For a primitive with a complete revalidatable negative fact—such as a managed readiness level, signal, queue absence or state predicate—it also acts as a validated transactional snapshot probe.

Together, `choice` and `or_else` form priority tiers:

```lua
preferred:or_else(choice(a, b, c))
choice(a, b):or_else(fallback)
```

The first expression gives `preferred` semantic priority and then admits any of `a`, `b` or `c` without source-order preference. The second admits `fallback` only after the complete choice scope containing both `a` and `b` has produced a valid `Retry` proof.

## 10. Guard activation lifetime

`guard(f)` is a reusable delayed option constructor. Each activated structural guard occurrence is evaluated at most once within one speculative activation.

A speculative activation is one live elaboration of an option in a candidate world. The option initially passed to `perform` has a root activation. Separate product lanes and choice positions receive separate activations, and each provisional result which progresses through `and_then` creates a child activation for the option returned by the continuation.

Consequently, host-language sharing is not semantic sharing:

```lua
local g = Op.guard(f)
Op.tensor({ g, g }) -- evaluates f twice
```

Explicit construction sharing is expressed with one outer guard:

```lua
Op.guard(function()
  local prepared = f()
  return Op.tensor({ prepared, prepared })
end) -- evaluates f once
```

The option returned for an activation remains fixed across local backtracking, bounded-search suspension, retained-search reconstruction and validation while the same transactional observations remain valid. A different proof progression or a changed observed version creates a different activation and reevaluates its guards. A new `perform` attempt starts with a fresh activation root.

The intended normal form is:

```text
relative or contextual surface operation
        ↓ guard activation
explicit resources + absolute values + core operations
```

For example, `clock:after_op(0.25)` elaborates once to `clock:at_op(concrete_deadline)`, and an omitted transfer target may elaborate to the Scope performing that occurrence. The residual itself does not retain or consult the activation view.

Guard evaluation is demand-driven. An unopened `or_else` fallback or an unentered choice branch need not evaluate its guards.

## 11. Normative callback phases

Every user or facility callback belongs to one of three phases. These are semantic requirements, not implementation advice.

### Phase 1: speculative search

This phase includes:

```text
guard builders
map functions
and_then continuations
resource transition and witness callbacks
effect key and merge functions
```

A phase-1 callback may run zero, one or several times as search branches, backtracks, suspends and resumes. It must be deterministic, non-yielding and replayable. It must not perform an option, spawn work, mutate external state, deliver an external fact or undertake work requiring compensation.

### Phase 2: committed-world effects

An effect kind has a pure `prepare` callback and a post-commit `discharge` callback.

`prepare(runtime, payload)` may run several times and its result may be discarded. It must therefore be deterministic, non-yielding and free of observable mutation. It must not reserve host capacity, acquire an external resource, deliver an event, perform, spawn or yield. It may return:

```text
prepared_record
nil, structured_refusal
```

A prepared record must contain a `discharge` function. Preparation may depend only on the payload, captured runtime configuration and managed facts already represented in the candidate. In particular, refusal must not depend on unversioned volatile host state: such a refusal may reject the preferred side of `or_else`, so it must remain valid under the candidate's validation facts.

All effects are merged and prepared before resource state is installed. Once the candidate commits, each prepared `discharge` runs once in stable first-occurrence order. Discharge may perform the irreversible host action represented by the effect, but it may not call `perform`; failure is fatal and post-commit.

### Phase 3: participant continuation

A `wrap` runs once after state installation and effect discharge, when the selected participant resumes. It may perform further options, spawn and interact with the outside world. It cannot change which world committed and its failure is a participant failure rather than a transaction rejection.

The phase boundary may be summarised as:

```text
search constructs possible worlds
effect preparation validates a possible committed obligation
effect discharge installs its irreversible consequence
wrap continues one participant after the committed world is complete
```

## 12. Wraps

`wrap` transforms one participant's committed result:

```text
op:wrap(f)
```

It cannot affect which world commits. It runs after state and effects have committed, inside the resumed participant's `perform` call.

```text
and_then constructs worlds
wrap observes committed worlds
```

A transactional continuation cannot consume a wrapped value. A wrap may begin a new transaction.

Conditional laws:

```text
wrap(op, identity) ≈ op
wrap(wrap(op, f), g) ≈ wrap(op, g ∘ f)
```

provided multiple return values and errors are preserved.

## 13. Defeat obligations

`op:on_defeat(effect)` attaches a typed obligation to an entered occurrence which loses to a committed competitor.

These do not count as defeat:

```text
Retry
Unknown
validation conflict
preferred-side refutation followed by fallback
an option which was never entered
```

Defeat effects are prepared and discharged with the winning world's effect batch.

## 14. Fixed primitive substrate

Trusted facilities compile to fixed primitive programme forms:

```text
read
patch
claim
conditional claim
serial machine transition
witnessed transition
version wait
linear exchange
snapshot
```

The kernel owns:

```text
search and alternative ordering
product visibility and provenance
Retry and Unknown
rollback
validation
atomic commit
```

A facility cannot manufacture Retry or commit independently.

### Versioned locations

A location contains an opaque committed value, a version and one fixed merge algebra. Current algebras are:

```text
replace
add
presence
finite_map
machine
```

The store defines sequential, independent-parallel and interacting-parallel composition for these algebras.

### Deterministic partial transducers

A serial machine transition has the semantic form:

```text
S -> Wait
S -> ReadySame(result)
S -> ReadyWrite(S', result)
```

Flow, the Lifetime store, RateLimiter and several coordination facilities use this form.

### Witnessed transitions

A witnessed transition lazily enumerates zero or more candidate successors:

```text
S -> Ready(S₁, r₁), Ready(S₂, r₂), ...
```

Each witness is an ordinary global alternative. Petri token bindings and Calendar interval choices use this form. The kernel, not facility code, owns progression, rollback and exhaustion of the cursor.

### Linear exchange

Rendezvous compiles to a one-use exchange intent. Matching remains provisional until both participants and their continuations close.

## 15. External observations

Signal, EventQueue and Readiness use host-maintained versioned locations updated through runtime-bound `ExternalFeed` capabilities. Clock options read host time and carry deadline checks.

An exhausted external option may contribute:

```text
negative validation check
host-actionable Interest
```

Interests explain how progress might occur; they are not evidence by themselves. Retry follows from exhaustive proof search and managed negative checks.

**External-observation law:**

```text
Any delivery which could make a preferred option ready must invalidate a
fallback proof before that fallback may commit.
```

## 16. Effects

Effects are typed committed-world obligations. Built-in uses include committed spawn and interrupt.

Identity is the ordered pair:

```text
(EffectKind object, raw key value)
```

The runtime does not stringify either component. Lua type and identity are preserved: numeric `1` differs from string `"1"`; false differs from `"false"`; two distinct tables remain distinct. `nil` is represented by a private sentinel. NaN is rejected because it cannot provide stable table-key identity.

Laws:

```text
losing worlds discharge no effects
key, merge and prepare are pure and replayable
all effects are merged and prepared before state installation
only effects with the same kind object and raw key are merged
distinct effects retain stable first-occurrence order
prepared effects discharge once after state installation
```

Effect kinds do not carry a global priority or numeric order. A facility which requires an inseparable discharge sequence should represent it as one compound effect. Effects are in-process obligations, not a durable outbox.

## 17. Lifetimes: custody, Grants and Closure

Lifetime operations make continuing responsibility part of the committed world:

```text
admit a dormant Lifetime
move custody
create or close a Grant
request or finish Closure
seal a Scope against new children
```

Principal laws:

```text
every live Lifetime has exactly one custodial parent
movement changes the parent of a complete subtree in one commit
Grants add non-custodial authority without changing custody
only the current custodian may issue a Grant
Closure requests run parent-first and finishing runs child-first
successful Closure progress is retained across later failure and retry
failed Closure remains represented in the Lifetime store
```

Closure protocols run only after the close operation commits and may themselves
perform options. They expose `request_op`, `finish_op` and optional `force_op`
phases. The engine's exclusive close token is private; callbacks receive only a
bounded Closure context.

Custody, Grant and Closure operations are ordinary `Op` values. The Lifetime
model therefore uses this algebra rather than defining a second set of choice or
sequencing operators.

## 18. Host boundary

Hosts supply time, blocking and readiness delivery. They do not define transaction semantics.

A truthful host must:

```text
advance or report time consistently
deliver external facts through authorised feeds
serialise entry into the runtime driver boundary
clear or refresh readiness hints after would-block outcomes
```

A host bug can invalidate assumptions about the external world, but cannot lawfully bypass feed validation.

## 19. Runtime scope

Transactions are coherent within one runtime commit. They are not:

```text
crash-durable logs
database transactions
distributed consensus
persistent message queues
```

External durability must be implemented through durable state and idempotent effects above this runtime.

## 20. Expected laws and non-laws

Expected laws, subject to callback purity and value packaging:

```text
always(v):and_then(k) ≈ k(v)
option:map(f) ≈ option:and_then(v -> always(f(v)))
choice() ≈ never
choice(a, b) ≈ choice(b, a) for admissible committed worlds
all({}) ≈ always(empty rows)
tensor({}) ≈ always(empty rows)
Unknown(primary) never enables primary:or_else(fallback)
losing worlds install no deltas and discharge no effects
```

Important non-laws:

```text
choice does not promise fairness or uniform probability
choice occurrence identity is not idempotent when defeat obligations are observable
or_else is not choice
or_else is not timeout
Retry is not failure to solve quickly
all is not tensor
wrap is not and_then
effects are not location writes
runtime transactions are not durable transactions
```

## 21. Implementation obligations

The current ledger machine and copy-on-branch reference machine consume the same option IR while maintaining independent speculative-state representations. The test suite exercises:

```text
global exchange and witness backtracking
nested product and continuation locality
proof-directed fallback and stale validation
all/tensor supply laws
external interests
custody and Closure
Flow and stream losing-branch safety
```

Fairness and uniform probability between perpetually available alternatives are not currently promised. `choice_seed` makes traversal reproducible for the same programme, request sequence and external inputs. Search budgets are optional controls and must never alter fallback semantics.

## 22. Summary

```text
option       proof search for a compatible committed world
Hit             constructive proof that a world exists
Retry           exhaustive present refutation under managed facts
Unknown         incomplete bounded search
all             joint commit without positive sibling supply
tensor          joint commit with compatible sibling hand-off
choice          unordered disjunction of acceptable committed worlds
or_else         fallback guarded by a valid preferred-side refutation
location delta  speculative state component
consequence     selected runtime obligation
wrap            participant-local post-commit continuation
```

That is the semantic centre of the library.
