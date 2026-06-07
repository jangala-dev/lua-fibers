# ET LuaTeX runtime

A compact eventful transaction algebra/runtime for `texlua`.

Public modules:

- `et.op`
- `et.runtime`
- `et.resources.channel`
- `et.resources.cell`
- `et.resources.ledger`
- `et.resources.event` (manual waitable resource used to pin wakeup semantics)

Additional public-facing documentation:

- `docs/algebra.md` — compact public operation algebra semantics.
- `docs/resources.md` — resource kind implementation process and trusted transactional machinery contract.

Run the test suite from the repository root:

```sh
texlua tests/run_all.lua
```

The main public algebra contract lives in `tests/test_op.lua`. Focused
invariant/resource/runtime tests live alongside it in `tests/`.

Run benchmarks:

```sh
texlua benchmarks/bench.lua
ET_BENCH_SCALE=100 texlua benchmarks/bench.lua
```

The runtime exposes both whole-run and externally stepped execution:

```lua
local Runtime = require('et.runtime')
local rt = Runtime.new()

-- Drive until one or more commits, absence, or idle.
rt:run()

-- Or drive from an external loop with bounded algebra work.
local st = rt:step({ max_work = 100 })
```

The current core keeps observable mutation in the runtime.  The algebra constructs candidate worlds and commit plans; the runtime applies resource state changes, publishes typed consequence obligations, resolves nacks, runs wraps, and resumes fibres.

The implementation uses three deliberately different error boundaries:

```text
recoverable algebra callbacks
  guard, map, and_then and with_nack callback bodies
  called through the protected callback boundary
  raw callback failures become structured callback_error values

trusted transactional machinery
  solver, resource protocol, prepare/apply, commit and consequence machinery
  not protected internally
  raw failures that escape a public driver call fail the runtime

public driver boundary
  run and step restore driver state on every exit
  structured ET errors are re-raised as themselves
  raw machinery failures are wrapped as fatal runtime_error values
```

After a fatal runtime error the runtime object is no longer usable; later public
entry points raise the stored fatal error.



## Typed consequence obligations

`Op.emit` accepts only typed consequence objects.  A consequence is a runtime-owned
obligation carried by a candidate world, not an arbitrary log item or after-commit
callback.  Consequence kinds define keying, merge, preparation and publication.
Resources may derive consequences from final committed state; the ledger resource
uses this to publish settlement obligations after ownership and close journals
have committed.

## Waitable resources

The algebra distinguishes current candidates from future wake interests:

```text
EvalResult = { cands = current transactional candidates, waits = future interests }
```

`or_else` is a residual fallback, not an eager biased choice.  The left branch is
searched first against the whole current transaction system.  The right branch is
not evaluated unless no current committed world can be found through the left
branch at that occurrence.  When fallback opens, the left branch's waits,
typed consequence obligations, wraps, protected nacks and speculative structure are abandoned.

A ready waitable source can therefore participate in the left-hand transaction
and suppress fallback.  A not-ready source does not suppress fallback; its wait
interest is reported only when no current transaction commits and no residual
fallback has replaced it.  The runtime then returns `{ tag = 'pending', kind =
'wakeup', waits = ... }`.

The corresponding resource and residual fallback checks are included in:

```sh
texlua tests/test_resources.lua
texlua tests/test_residual_or_else.lua
```

## Internal layout

The internal modules now follow the execution pipeline:

```text
et.op
  -> et.algebra.*      -- evaluation, candidates, summaries, results
  -> et.solver.*       -- search, cursor and rendezvous closure
  -> et.commit.plan    -- inert commit plan construction
  -> et.runtime        -- scheduling and observable effect application
  -> et.resources.*    -- concrete resources and the local resource protocol
```

The rendezvous solver is deliberately not named after channels.  Channels are the
current public rendezvous primitive, but the solver works over generic
rendezvous endpoint records.
