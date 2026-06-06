# Public operation algebra

The public operation algebra lives in `et.op`.  An operation is an immutable
syntax value describing a transaction.  A `Runtime` executes operations only when
a fibre calls `rt:perform(op)`.

```lua
local Op = require('et.op')
local Runtime = require('et.runtime')

local rt = Runtime.new()
rt:spawn(function()
  local x, y = rt:perform(Op.always(1, 2))
end)
rt:run()
```

`perform` suspends the current fibre.  The solver searches the currently waiting
fibres for a closed committed world.  If a world commits, resource mutation,
transaction consequence publication and nack settlement happen before any
selected fibre is resumed.  The selected fibre is then resumed inside `perform`
with the raw values and the selected post-commit value transformer.  That
transformer is applied in the resumed fibre before `perform` returns.

## Values and transactional candidates

Operations evaluate to current transaction candidates.  A candidate may contain:

- returned values;
- rendezvous endpoints;
- tentative resource records;
- deferred continuations waiting for unresolved rendezvous values;
- consequences from `emit`;
- post-commit value transformers from `wrap`;
- selected or lost nack obligations.

Candidate values may contain internal placeholders.  Placeholders are immutable;
rendezvous resolution is stored in candidate-local substitutions.  This means
candidate cloning shares value structure and only copies the search frontier.

Evaluation may also produce future wake interests and residual fallback points.
Those are not candidates.  Wake interests are reported only if no current
transaction can commit.  Residual fallback points belong to `or_else` and may be
opened only after the current search environment proves absence of a committing
world through the left branch.

## Core constructors

### `Op.always(...)`

Always succeeds now and returns its arguments as multiple values.

```lua
Op.always("a", "b")
```

### `Op.never()`

Has no current candidates and no wake interests.  It represents absence, not a
failed exception.

### `Op.emit(item)`

Succeeds with `true` and appends `item` to the transaction consequence log if the
candidate commits.  Emits from losing, absent or abandoned branches are not
published.

### `Op.guard(fn)`

Calls `fn` to produce an operation for the current attempt, then evaluates that
operation.  The result is cached only within the current perform attempt.  Guards
are therefore not permanent memo tables; a later attempt may re-run the guard.

`fn` should return an operation.

```lua
Op.guard(function()
  if ready then return Op.always("ready") end
  return Op.never()
end)
```

### `Op.choice(...)`

Eager competing alternatives.  Each branch is evaluated as an offer in the
current transaction space.  A committed branch wins; protected alternatives that
were entered and lost may produce nacks.

```lua
Op.choice(p, q, r)
```

If more than one world is available, the implementation chooses deterministically
from the search order.  Code should not rely on fairness between equally valid
choices.

### `p:or_else(q)`

Lazy ordered residual fallback, not eager biased choice.

Semantics:

1. evaluate and search the left branch `p` first;
2. give `p` the full current global transaction search, including rendezvous
   with partners elsewhere and partner backtracking;
3. if no current committed world can be found through this occurrence of `p`,
   abandon `p` and open `q`;
4. search `q` as the transaction at that point.

The right branch is not evaluated unless fallback opens.  When fallback opens,
the left branch's waits, consequences, post-commit transformers, protected nacks and speculative
structure are discarded.

Consequences:

- a ready primary suppresses fallback;
- a primary that can rendezvous with a current partner suppresses fallback;
- a not-ready waitable primary does not suppress fallback;
- absence under `or_else` does not nack;
- once fallback is opened, the fallback branch is an ordinary competing offer
  and can lose to an outer `choice`.

```lua
primary:or_else(fallback)
```

### `Op.with_nack(fn)` and `Op._nack(ref)`

`with_nack` creates a protected obligation and passes it to `fn`:

```lua
local saved
local p = Op.with_nack(function(nack)
  saved = nack.obligation
  return Op.always("offer")
end)
```

If a protected occurrence is selected, its obligation becomes selected.  If it
entered transaction competition and lost to another committed world, its
obligation becomes lost.  `Op._nack(ref)` succeeds with `true` once `ref` is
lost; otherwise it is absent.

Nacks observe loss, not mere absence.  In particular, an absent left branch of
residual `or_else` does not nack.

### `Op.all({ ... })`

Parallel product without internal rendezvous closure between lanes.  Every lane
must be compatible with the others.  Lanes may still rendezvous with external
fibres.  The result is one table whose entries are the packed value results of
the lanes.  A lane-local `wrap` applies to that lane's packed result after
commit, before any outer product wrap is applied.

```lua
Op.all({ p, q })
```

Use `all` when lanes are independent participants that should not communicate
with each other internally.

### `Op.tensor({ ... })`

Parallel product with internal rendezvous closure between lanes.  Every lane is
combined into the same transaction, and compatible get/put endpoints in distinct
lanes may close internally.  The result shape is the same as `all`: one table of
packed lane results.  Lane-local wraps run after internal rendezvous closure,
left-to-right by lane order, before an outer product wrap.

```lua
Op.tensor({ ch:get_op(Op), ch:put_op(Op, "x") })
```

Use `tensor` when the lanes form a local transactional network.

## Sequential combinators

### `p:map(fn)`

Transforms the values produced by `p` without adding a new transaction boundary.
If `p`'s values contain unresolved rendezvous placeholders, the map is deferred
until the placeholders are resolved.

```lua
cell:get_op(Op):map(function(x) return x + 1 end)
```

### `p:and_then(fn)`

Sequentially composes transactions.  `fn` is called with the resolved values of
`p` and must return another operation.  The right-hand operation sees the
tentative resource overlay created by the left-hand candidate.

```lua
cell:set_op(Op, 7):and_then(function()
  return cell:get_op(Op) -- sees 7 transactionally
end)
```

If the left values are unresolved, the bind is deferred until rendezvous closure
resolves them.

## Commit boundary

### `p:wrap(fn)`

Registers a post-commit participant continuation.  `fn` runs only after the
candidate has committed and resource/consequence effects have been applied.  It
runs inside the resumed fibre, inside `perform`, before `perform` returns.

`wrap` is therefore post-commit, but it is not a transaction consequence.  It may
perform a fresh transaction, and failure in a wrap does not roll back the commit
that selected it.

`wrap` is also a boundary for further transactional construction: `map` and
`and_then` cannot be applied after it, or to an operation whose product or
choice structure already contains a wrap.  Structural combinators such as
`all`, `tensor`, `choice` and `or_else` may contain wrapped sub-operations;
post-commit transformation then follows the value structure.

```lua
p:wrap(function(x) return decorate(x) end)
```

Multiple wraps form a stack and are applied in construction order:

```lua
p:wrap(f):wrap(g) -- returns g(f(value))
```

Wraps may also be attached to product lanes:

```lua
Op.all({
  ch_a:get_op(Op):wrap(f),
  ch_b:get_op(Op):wrap(g),
}):wrap(h)
```

If the product commits, the lane wrappers run left-to-right after commit and the
outer wrapper then receives the product of wrapped lane results.  Conceptually,
this returns `h({ f(a), g(b) })`, using the packed lane-result shape of `all` and
`tensor`.

Because wrap code runs in the resumed fibre, it may call `perform`:

```lua
rt:perform(
  p:wrap(function(x)
    local y = rt:perform(q)
    return combine(x, y)
  end)
)
```

The inner `perform(q)` is a new transaction after `p` has committed; it is not
part of `p`'s committed world.

## Public resource operations

Resource modules expose operations by returning `Op._resource(...)` nodes.  The
current public resources are:

- `et.resources.cell` — transactional value cell;
- `et.resources.channel` — rendezvous get/put channel;
- `et.resources.ledger` — ownership transfer and settlement example;
- `et.resources.event` — manual waitable event.

Examples:

```lua
local Cell = require('et.resources.cell')
local Channel = require('et.resources.channel')

local c = Cell.new(0)
local ch = Channel.new()

c:get_op(Op)
c:set_op(Op, 10)
c:update_op(Op, function(x) return x + 1 end)

ch:get_op(Op)
ch:put_op(Op, "message")
```

## Runtime outcomes

`rt:run()` drives until it commits at least one transaction, becomes pending on a
future wake interest, or reaches absence/idle.

`rt:step(opts)` performs one scheduler transition.  With `opts.max_work`, the
algebra search is bounded and resumable through a cursor.

Common return tags:

- `{ tag = 'found' }` — a transaction committed;
- `{ tag = 'pending', kind = 'wakeup', waits = ... }` — no current transaction
  committed, but future wake interests remain;
- `{ tag = 'absent' }` — no compatible transaction exists now;
- `{ tag = 'idle' }` — no fibres are live.

## Laws and useful intuitions

These are the intended public intuitions, not rewrite rules for arbitrary effectful
Lua functions:

- `always` is the unit for `and_then`.
- `never` is absence.
- `choice` is eager competition.
- `or_else` is ordered residual fallback.
- `all` composes independent lanes.
- `tensor` composes lanes and permits internal rendezvous.
- resource effects are atomic and all-or-nothing.
- consequences are published only by the committed world.
- post-commit transformations from losing worlds are discarded.
- selected wraps run in value-structure order in the resumed fibre after
  consequence publication and before `perform` returns.
- choice loss may nack; residual absence does not.
