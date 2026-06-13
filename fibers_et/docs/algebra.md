# Public operation algebra

The public operation algebra lives in `fibers.base.op`.  An operation is an immutable
syntax value describing a transaction.  A `Runtime` executes operations only when
a fibre calls `rt:perform(op)`.

```lua
local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')

local rt = Runtime.new()
rt:spawn_raw(function()
  local x, y = rt:perform(Op.always(1, 2))
end)
rt:run()
```

`perform` suspends the current fibre.  The solver searches the currently waiting
fibres for a closed committed world.  If a world commits, resource mutation,
typed consequence publication and nack settlement happen before any
selected fibre is resumed.  The selected fibre is then resumed inside `perform`
with the raw values and the selected post-commit value transformer.  That
transformer is applied in the resumed fibre before `perform` returns.

## Values and transactional candidates

Operations evaluate to current transaction candidates.  A candidate may contain:

- returned values;
- rendezvous endpoints;
- tentative resource records;
- deferred continuations waiting for unresolved rendezvous values;
- typed consequence obligations from `emit`;
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

### `Op.emit(consequence)`

Succeeds with `true` and contributes a typed runtime obligation to the current
candidate world.  `consequence` must be a consequence object constructed by a
consequence kind; arbitrary Lua values and callbacks are rejected at construction
time.

When candidate worlds combine, their consequence sets are keyed and merged by
kind.  Duplicate obligations may collapse, and conflicting obligations reject the
candidate world.  If the selected world commits, prepared obligations are
published by trusted runtime machinery after resource journals are applied and
before any selected fibre resumes.  Emits from losing, absent or abandoned
branches are discarded.

### `Op.guard(fn)`

Calls `fn` to produce an operation for the current attempt, then evaluates that
operation.  The result is cached only within the current perform attempt.  Guards
are therefore not permanent memo tables; a later attempt may re-run the guard.

`fn` should return an operation.  The runtime passes the current evaluation context to the callback; existing zero-argument guards may ignore it.  The context exposes the runtime as `ctx.rt`, so guarded construction can depend on attempt-time host state such as `ctx.rt:now()` without storing that state in the operation value.

```lua
Op.guard(function(ctx)
  if ready_at <= ctx.rt:now() then return Op.always("ready") end
  return Op.never()
end)
```

### `Op.choice(...)`

Eager competing alternatives.  Each branch is evaluated as an offer in the
current transaction space.  A committed branch wins; protected alternatives that
were entered and lost may produce nacks.

```lua
Op.choice(p, q, r)
Op.choice({ p, q, r })
Op.choice(p, { q, r }, Op.choice(s, t))
```

`choice` accepts operation values and dense arrays of operation values.  It
flattens nested arrays and bare nested `choice` nodes at construction time.
Named maps are intentionally rejected here; use `Op.named_choice` when branch
labels should be part of the result.

```lua
Op.named_choice({
  { "input", input_op },
  { "timeout", timeout_op },
})
-- returns: name, ...
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

For products whose lanes are naturally named, `named_all` returns a record.
Single-valued lanes are exposed directly; multi-valued lanes keep their packed
row.  Raw rows are also available as `record._rows[name]`.

```lua
Op.named_all({
  { "left", left:state_op() },
  { "right", right:state_op() },
})
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
Op.tensor({ ch:get_op(), ch:put_op("x") })
```

Use `tensor` when the lanes form a local transactional network.

## Sequential combinators

### `p:map(fn)`

Transforms the values produced by `p` without adding a new transaction boundary.
If `p`'s values contain unresolved rendezvous placeholders, the map is deferred
until the placeholders are resolved.

```lua
cell:read_op():map(function(x) return x + 1 end)
```

### `p:and_then(fn)`

Sequentially composes transactions.  `fn` is called with the resolved values of
`p` and must return another operation.  The right-hand operation sees the
tentative resource overlay created by the left-hand candidate.

```lua
cell:write_op(7):and_then(function()
  return cell:read_op() -- sees 7 transactionally
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
  ch_a:get_op():wrap(f),
  ch_b:get_op():wrap(g),
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

- `fibers.base.cell` — transactional Cell;
- `fibers.base.channel` — rendezvous Channel;
- `fibers.base.source` — host/time/readiness Source;
- `fibers.base.region` and `fibers.base.task` — lifetime and running work;
- 
Examples:

```lua
local Cell = require('fibers.base.cell')
local Channel = require('fibers.base.channel')

local c = Cell.new(0)
local ch = Channel.new()

c:read_op()
c:write_op(10)
c:read_op():and_then(function(x)
  return c:write_op(x + 1):map(function() return x + 1 end)
end)

ch:get_op()
ch:put_op("message")
```


## Host interface, time and runtime phase

`Runtime.new` accepts an optional host table:

```lua
local rt = Runtime.new({
  host = {
    now = function(_rt) return monotonic_time end,
    trace = function(event) end,
    on_error = function(err) end,
  },
})
```

The core runtime does not choose a wall-clock, print traces, block, or install a
process-wide scheduler.  Hosts and standalone runners provide those behaviours
outside the transaction kernel.  The built-in runner uses `Runtime:run` as its
efficient internal driver and asks a host adapter to block only when the runtime
reports pending waits.

`rt:now()` returns the host's monotonic runtime time.  If no host clock is
provided, it returns `0`.  Relative-time operations should be built with
`guard`, so the deadline is fixed for the current perform attempt rather than
when the operation value was constructed.

The runtime maintains a small phase discipline without putting the hot search path
behind a protected phase wrapper.  The public authority checks are simpler:

- `perform` is legal only when called by the currently resumed runtime fibre;
- `step` and `run` are external driver calls and are rejected from a resumed
  fibre;
- `spawn` is legal from external code before or between driver calls, and from a
  resumed fibre; it is rejected from runtime-internal work such as guarded
  construction, resource evaluation, commit, or consequence publication;
- `commit` and `consequence` remain named phases for diagnostics around resource
  mutation and consequence handlers.

The solver and prepare path do not set a global `search` or `prepare` phase.
Search-specific information belongs in the evaluation context.  This keeps
`perform` and `spawn` protection independent of hot-path phase restoration.
`perform` is still rejected inside `guard`, `map`, `and_then`, resource callbacks
and consequence handlers, but it is allowed inside `wrap` because `wrap` runs in
the resumed fibre after the selected transaction has committed.

Phase violations and runtime failures are reported as structured error objects
with fields such as `kind`, `phase`, `action`, `fibre`, `committed`, `fatal` and
`message`.  The default policy still raises the error.  If the host provides
`on_error` or `report_error`, the runtime reports the structured error before
raising it.  Fatal errors are also stored on the runtime; subsequent public
entry points raise the stored fatal error rather than trying to continue.

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
- `{ tag = 'reject_candidate' }` — the candidate selected by search could not be
  prepared, for example because a consequence kind returned a structured
  refusal;
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
- typed consequence obligations are published only by the committed world.
- wraps from losing worlds are discarded.
- selected wraps run in the resumed fibre after consequence publication and before
  `perform` returns.
- choice loss may nack; residual absence does not.


### Recoverable algebra callbacks

Transaction-construction callbacks such as `guard`, `map`, `and_then`, and
`with_nack` are recoverable algebra callbacks.  They are non-yielding,
speculative callback bodies supplied by ordinary user code.  The runtime calls
them through a protected callback boundary so that a programmer error is
reported as a structured `callback_error` instead of corrupting the runtime.

A recoverable algebra callback may construct or choose operation values, but it
must not call `perform`, `spawn`, `step` or `run`.  Such authority violations are
reported as structured phase errors.

`wrap` is deliberately outside this category.  A wrap runs later in the resumed
fibre after the selected transaction has committed.  It may yield by calling
`perform`, and failure there is ordinary resumed-fibre failure rather than
failure of the transaction that has already committed.

### Trusted transactional machinery

The solver, resource protocol, prepare/apply path, commit machinery and
mandatory consequence preparation/publication are trusted transactional machinery.  They are
not individually protected by recovery wrappers.  An error here is treated as an
implementation or resource-integrity failure, not as a transactional abort and
not as a losing candidate world.

Resource kind implementations are part of this trusted machinery.  Methods such
as `eval`, `project`, `merge_seq`, `merge_par`, `prepare`, `apply`, `summary` and
`clone` must be total for valid inputs, must not yield, and must not call
`perform`, `spawn`, `step` or `run`.  Functions executed inside resource
operations, such as a cell update function, inherit this contract when the
resource kind evaluates them during transactional resource interpretation.

If a raw error escapes from trusted transactional machinery through a public
driver call, the public driver boundary restores driver state, records a fatal
structured `runtime_error`, and re-raises that fatal error.  The transaction
runtime object should then be considered failed and unusable.

Structured fibers errors are re-raised as themselves.  They do not become fatal
unless they were already fatal.

### Public driver boundary

Public `run` and `step` calls have a narrow driver exit boundary.  Its job is to
restore public driver state on every exit and then re-raise the appropriate
error.  It does not make solver, resource, prepare, commit or consequence code
recoverable.

Mandatory consequence publication happens after resource commit.  If a prepared
consequence publisher raises, the transaction remains committed, but the runtime
records a fatal `consequence_error`, reports it to the host if configured, and
rejects later public entry points with the stored fatal error.

Consequence kinds may also return a structured refusal during merge or prepare.
That is a candidate-world rejection, not a fatal runtime failure.  A raw Lua
error escaping from consequence kind machinery remains a trusted-machinery
failure.
