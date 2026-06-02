# Eventful Transaction Fibers

`et_fibers` is an executable proof-net specimen for **Eventful Transactions**: a small concurrency model where a fibre proposes a whole committed world, not just a single event and not just an isolated memory transaction.

Repository structure:

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

The tensor proof sees the raw values. Resources commit. Commit events fire. Then the resumed fibre runs the structured post-commit value program, and only then does `Op.perform` return. A wrapper may delay the return value, but it cannot delay, affect, or roll back the world that already committed.

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

Bind/map callbacks are not invoked by ordinary expression expansion. They run only when proof search reduces an explicit `BindFrame` or `MapFrame`; post-commit wrappers run only when the resumed fibre interprets its `PostCommitFrame`.

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

Lane-local wrappers are product-shaped; they are not flattened into an undifferentiated list.

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
validate fragments
prepare commit fragments
install resource state
emit commit descriptors
resume participating fibres with post-commit frames
run post-commit value programs inside those fibres
```

## Why a proof net?

The implementation uses proof-net vocabulary because the runtime object we are constructing really is graph-shaped.

```text
roots       parked fibre attempts
ports       open communication/resource endpoints
cuts        rendezvous between compatible ports
boxes       tensor/all/product structure
bind links  transactional proof continuations
map links   pure transactional raw-value transformations
join links  product completion
prefer links preferential choice sites
boundary links post-commit value boundaries
fragments   resource-local proof objects
worlds      closed, valid, committable proof candidates
```

A scheduler that merely resumes coroutines is the wrong centre of gravity. The scheduler’s real job is to search for a closed proof, validate its resource fragments, discharge its obligations, and interpret the committed world.

This gives the runtime a few hard laws:

```text
No closed proof, no commit.
No fragment merge, no world.
No absence proof, no fallback.
No budget-as-absence.
No post-boundary transactional continuation.
No post-commit wrapper can affect the world that already committed.
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

The next steps are to harden the resource protocol, improve diagnostics, add live-offer/speculative-port modality, and eventually add richer supervision/cancellation semantics.
