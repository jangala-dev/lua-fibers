# Eventful Transaction Fibers

`et_fibers` is an executable proof-net specimen for **Eventful Transactions**: a small concurrency model where a fibre proposes a whole committed world, not just a single event and not just an isolated memory transaction.

The repository is now intentionally split into a small core, two resource modules, tests, and demos:

```text
et_fibers/
  etfcore.lua
  channel.lua
  ledger.lua
  tests/
    test_etfcore.lua
    run.lua
  demos/
    demo_triple_swap.lua
    demo_ledger.lua
```

Run from the bundle root:

```sh
lua tests/run.lua
lua demos/demo_triple_swap.lua
lua demos/demo_ledger.lua
```

`luajit` or `texlua` should also work where available.

## A first taste

The surface idea is deliberately close to CML-style events: build operations, compose them, and `perform` one when the surrounding fibre is ready to commit.

```lua
local core = require('etfcore')
local Op = core.Op
local Runtime = core.Runtime
local Channel = require('channel')

local rt = Runtime.new()
local ch = Channel.new('triple')

local function pair(a, b)
  return { a, b }
end

local function triple_swap_op(ch, x)
  local reply = Channel.new('reply-' .. tostring(x))

  -- Either offer our value and wait for a reply...
  local client = ch:put({ x = x, reply = reply }):and_then(function()
    return reply:get()
  end)

  -- ...or become the leader that joins two other offers.
  local leader = ch:get():and_then(function(m2)
    return ch:get():and_then(function(m3)
      return m2.reply:put(pair(m3.x, x)):and_then(function()
        return m3.reply:put(pair(x, m2.x)):and_then(function()
          return Op.always(pair(m2.x, m3.x))
        end)
      end)
    end)
  end)

  return Op.choice(client, leader)
end

for _, x in ipairs({ 11, 12, 13 }) do
  rt:spawn(function()
    local got = Op.perform(triple_swap_op(ch, x))
    print(x, got[1], got[2])
  end, 'swapper-' .. tostring(x))
end

rt:run()
```

The remarkable thing is not that the example communicates. The remarkable thing is that the whole multi-party exchange commits as one world. Either the proof closes and every participant resumes with a coherent result, or nothing in that proposed transaction happens.

`wrap` marks the post-commit value boundary:

```lua
local result = Op.perform(
  Op.tensor({
    inbox:get():wrap(function(message)
      -- This runs after the tensor transaction has committed.
      -- It may even perform a fresh transaction.
      return decorate(message)
    end),
    clock:get(),
  })
)
```

The tensor proof sees the raw values. Resources commit. Commit events fire. Then the resumed fibre runs the structured post-commit value program, and only then does `Op.perform` return. A post-commit callback may delay the return value, but it cannot delay, affect, or roll back the world that already committed.

`guard` is a delayed operation constructor. It is evaluated when a root attempt is expanded, not when the Lua value is built:

```lua
local delayed = Op.guard(function()
  -- Read attempt-time context and construct the operation to offer.
  -- Do not perform, spawn, or mutate resources here.
  return deadline_op(now() + 10)
end)
```

A guard contributes no evidence of its own. The operation it returns contributes ordinary ports, fragments, descriptors, and post programs. Guard expansion is memoized on the current `RootAttempt`, proof address, and decision prefix, so proof-search replay reuses the same returned operation. Function fallbacks passed to `or_else` are normalized through `Op.guard`, giving them the same replay-stable semantics.

`with_nack` protects an occurrence and passes an ordinary nack operation to the callback:

```lua
local protected = Op.with_nack(function(nack)
  return Op.choice(
    server:get(),
    nack:wrap(function()
      return 'the protected occurrence was lost or withdrawn'
    end)
  )
end)
```

The callback is evaluated during proof expansion, not Lua construction. The protected operation contributes selected-settlement evidence to worlds that pass through it. The runtime publishes only protected occurrences retained in a parked root frontier. If that same root attempt resolves through another published alternative, the protected occurrence is settled `lost`; if the attempt is withdrawn, it is settled `withdrawn`; if the protected world commits, it is settled `selected`. A nack operation closes only after a prior `lost` or `withdrawn` settlement. It cannot observe loss being created by the same commit plan.


## The ET idea

`et_fibers` takes inspiration from three traditions:

- **CML** gives us first-class synchronous events: operations can be built, chosen between, and synchronized by fibres.
- **Transactional Events** show that synchronizing events can be composed transactionally: multi-party communication can commit or abort as a unit.
- **STM** gives us the discipline of tentative effects, validation, and atomic commit.

Eventful Transactions shifts the centre of gravity slightly. The transaction is the noun.

An operation is not “an event that might happen”. It is a description of a possible committed world:

```text
fibres contribute open ports
resources contribute tentative fragments
proof search reduces explicit BindFrame/MapFrame continuations
proof search closes ports with cuts
closed proofs become worlds
valid, committable worlds commit atomically
post-commit programs compute returned values
```

That framing lets channels, resource updates, preference, product structure, and post-commit effects live in one model.

## The algebra

The core operations are:

```text
always(v)       immediately contributes raw value v
never           contributes no proof
request(r, q)   exposes a resource request, such as channel put/get
access(r, q)    contributes a resource-local fragment step
emit(e)         records a commit event descriptor
choice(a, b)    nondeterministic choice
or_else(a, b)   preferential choice: try a unless its absence is proved
tensor(xs)      product whose lanes may internally synchronize
all(xs)         product whose lanes may not internally synchronize
and_then(a, k)  transactional continuation
map(a, f)       pure transactional raw-value transformation
wrap(a, f)      post-commit value continuation
guard(f)        delayed attempt-local operation construction
with_nack(f)    protected occurrence plus ordinary nack operation
perform(a)      search, commit, then return post-commit values
```

The distinction between `and_then`, `map`, and `wrap` is fundamental:

```text
and_then composes worlds before commit.
map transforms raw transactional values before commit.
wrap composes values after commit.
```

The implementation represents these as different links/frames rather than one vague callback mechanism:

```text
BindLink / BindFrame
  callback returns an Op and extends the transactional proof

MapLink / MapFrame
  callback returns raw values and must be pure/non-performing

BoundaryLink / PostProgram
  callback runs after commit and may perform a fresh transaction
```

Bind/map callbacks are not invoked by ordinary expression expansion. They run only when proof search reduces an explicit `BindFrame` or `MapFrame`; post-commit value programs run only when the resumed fibre interprets its `PostCommitFrame`.

So this is rejected:

```lua
op:wrap(f):and_then(k)
```

because `k` is transactional, while `f` only runs after the transaction has already committed.

## Raw values and post-commit values

Every operation has two layers:

```text
raw transactional value
  visible to proof search, joins, cuts, fragments, preferences, and transactional continuations

post-commit value program
  run only after the world commits, inside the resumed fibre
```

For example:

```lua
Op.tensor({
  a:get():wrap(f),
  b:get():wrap(g),
}):wrap(h)
```

has raw committed value:

```lua
{ a_value, b_value }
```

and post-commit return value:

```lua
h({ f(a_value), g(b_value) })
```

Lane-local post programs are product-shaped; they are not flattened into an undifferentiated list.

## Products

`tensor` and `all` both build product boxes. Their difference is topological:

```text
tensor
  sibling lanes may rendezvous with each other

all
  sibling lanes are independent; sibling internal cuts are forbidden
```

This makes the distinction executable:

```lua
Op.tensor({ ch:put('x'), ch:get() }) -- can close internally
Op.all({ ch:put('x'), ch:get() })    -- cannot close by self-rendezvous
```

Products also obey a context law:

```text
visible context for a lane = inherited base + lane-local delta
contribution of a lane     = lane-local delta only
world contribution         = product base once + each lane delta once
```

That law matters for resource fragments, preference obligations, decisions, commit events, and post-commit programs.

## Resources

A resource supplies a fragment theory. In the current model, a resource supports operations shaped like:

```text
empty_fragment()
step_fragment(fragment_view, local_fragment, request)
merge_fragments(a, b)
validate_fragment(fragment)
prepare_commit_fragment(fragment)
commit_fragment(fragment)
try_match(request_a, request_b)
```

The important algebraic idea is that a transaction does not mutate a resource while searching. It accumulates fragments. A world may commit only if all fragments merge and validate.

For product lanes, reads see:

```text
base fragment + local lane fragment
```

but the lane writes back only its local delta.

## Preferential choice

`or_else(primary, fallback)` is not “try primary quickly, then give up”. It creates a preference obligation.

A fallback world is valid only as a proof candidate. It becomes committable only when the runtime has proved absence of a better **committable** primary world under the same decision prefix and generation.

The proof-search result is tri-valued:

```text
found   a committable world exists
absent  the searched neighbourhood is closed and no committable world exists
budget  search was not sufficient; absence has not been proved
```

`budget` is never treated as `absent`.

Committability checks share a generation-stable judgement context and fuel budget. A preference obligation does not ask merely “can the primary branch close as a valid proof?”; it asks “can the primary branch produce a committable world?”. A valid but dominated primary candidate is skipped while the search continues; cyclic judgement dependencies are treated as `budget`, never as absence.

The committability API requires an explicit `JudgementContext`; there is no alternate raw-number call path for nested committability checks. This keeps all nested obligations inside the same generation/fuel/memo/recursion context.

Nested `or_else` records decision paths precisely:

```text
prefix = decisions before this preference site
site   = this preference site
force  = primary
```

So an inner fallback obligation under an outer fallback says:

```text
replay outer = fallback
then test inner = primary
```

not “search the whole program again and hope we meant the same branch”.

## Evidence certificates and commit plans

A closed proof carries evidence, but the core now distinguishes local proof evidence from the materialized commit certificate. Evidence is inert during search: proof search constructs local `EvidenceDelta` values, judgement checks the resulting `WorldEvidence`, and `CommitPlan` interprets it exactly once.

```text
RootAttempt
  attempt identity, liveness, published settlements, settlement memo, guard expansion memo

EvidenceDelta
  local proof-carried facts on frames/products
  may have a base and a local post program

WorldEvidence
  materialized global commit certificate
  resource fragments, pre-commit obligations, commit descriptors, selected settlements
  no base and no post program

ResumptionEvidence
  per-root raw returned values plus PostProgram

CommitPlan
  prepared interpretation of WorldEvidence + RootAttempts + ResumptionEvidence
```

A `World` owns one global `WorldEvidence` certificate for commit-time facts, plus a separate per-root `resumptions` certificate:

```text
World {
  closed proof entries/cuts
  evidence    -- WorldEvidence, the global commit certificate
  resumptions -- ResumptionEvidence values, one per participating root
}
```

This distinction matters because a single committed world may resume multiple roots, each with its own returned value and post-commit program. There is no single world-level post program.

Feature placement is now deliberately boring:

```text
channel / ledger
  EvidenceDelta.resources.fragments -> WorldEvidence.resources.fragments

or_else
  EvidenceDelta.pre_commit.obligations -> WorldEvidence.pre_commit.obligations

emit
  EvidenceDelta.commit.descriptors -> WorldEvidence.commit.descriptors

wrap
  EvidenceDelta.post.program locally -> ResumptionEvidence.post_program

future with_nack
  EvidenceDelta.commit.selected_settlements -> WorldEvidence.commit.selected_settlements
  RootAttempt.published_settlements + Runtime SettlementCells

guard
  attempt-local delayed Op construction, memoized on RootAttempt.guard_memo
```

The emerging settlement algebra is present internally but no public `with_nack` operator has been added yet. A proof may carry selected settlement references as commit evidence; runtime settlement cells are interpreted only by commit. Settlement publication is owned by the current `RootAttempt`; publishing without an attempt is rejected. This preserves the intended law: search may discover evidence, but search does not publish, lose, select, or settle anything live.

`CommitPlan.prepare` is a dry-run phase: it validates that each resumption still points at the task's current parked `RootAttempt`, prepares resource descriptors, and computes settlement updates. `CommitPlan.apply` revalidates those attempts before mutation, then installs resources, applies the prepared settlement updates, bumps the generation, emits descriptors, and resumes participants.

## Worlds

A closed proof is not automatically a commit.

```text
closed proof
  all required ports/cuts/joins are closed

valid world
  resource fragments merge and validate

committable world
  valid, and all preference obligations are discharged
```

Only a committable world may commit.

Commit order is:

```text
validate evidence/resources
prepare a CommitPlan
install resource state
interpret settlement evidence
bump generation
emit commit descriptors
resume participating fibres with post-commit frames
run post-commit value programs inside those fibres
```

## Why a proof net?

The implementation uses proof-net vocabulary because the runtime object we are constructing really is graph-shaped.

```text
roots       parked fibre attempts
spec ports  speculative communication/resource endpoints
cuts        rendezvous between compatible ports
boxes       tensor/all/product structure
bind links  transactional proof continuations
map links   pure transactional raw-value transformations
join links  product completion
prefer links preferential choice sites
boundary links post-commit value boundaries
fragments   resource-local proof objects
evidence    local deltas and world commit certificates
worlds      closed proof candidates with WorldEvidence + ResumptionEvidence
commit plans checked interpretation of committed worlds
```

A scheduler that merely resumes coroutines is the wrong centre of gravity. The scheduler’s real job is to search for a closed proof, validate its resource fragments, discharge its obligations, and interpret the committed world.

This gives the runtime a few hard laws:

```text
No closed proof, no commit.
No fragment merge, no world.
No absence proof, no fallback.
No budget-as-absence.
No post-boundary transactional continuation.
No post-commit callback can affect the world that already committed.
```

## Current status

This is an executable sketch, not yet a polished package. It currently includes:

- `etfcore.lua`: core Op algebra, proof frames/links, proof search, worlds, runtime, judgement context.
- `channel.lua`: synchronous channel resource.
- `ledger.lua`: ledger fragment resource used by the demos/tests.
- `tests/test_etfcore.lua`: semantic regression tests for the core specimen.
- `tests/run.lua`: test runner.
- `demos/demo_triple_swap.lua`: triple rendezvous demo.
- `demos/demo_ledger.lua`: ledger transfer/close demo.

The split is mechanical, but the core now has a first-class clean architecture around RootAttempt, EvidenceDelta, WorldEvidence, ResumptionEvidence, and CommitPlan. The next steps are to harden the resource protocol, improve diagnostics, and build richer supervision/cancellation semantics on top of the settlement-aware withdrawal path.
