# Scope

`Scope` is the ordinary lightweight container for lifetimes.  It is also the
core calculus from which larger lifetime facilities can be built.

Most code should meet it in this form:

```lua
local fibers = require('fibers')

fibers.scope(function(scope)
  local task = fibers.spawn(function()
    return 'ok'
  end)

  local value = fibers.perform(task:await_op())
end)
```

The point is simple:

```text
create lifetime-bearing things inside a scope
settle them when the scope exits
report settlement failure instead of hiding it
move or borrow things explicitly when they cross the boundary
```

For the underlying laws, see `docs/scope_laws.md`.  For the broader theory, see
`docs/lifetime-calculus.md`.

## Ambient scope

`fibers.run(fn, policy)` creates the runtime and the root scope for lifetime-bearing work. `fibers.scope(fn, policy)` creates a nested lifetime. Both raising forms return the body values only after the boundary has been accounted for; `fibers.try_run` and `fibers.try_scope` return a checked result/report instead.

Inside the body, ambient constructors use the current scope:

```lua
fibers.scope(function()
  local task = fibers.spawn(function()
    return 7
  end)
end)
```

Raw unstructured fibres remain explicit through `fibers.spawn_raw`.  Code that
creates lifetime-bearing values outside a current scope should provide an
explicit owner or fail clearly.

## Custody verbs

The calculus-facing verbs are deliberately few:

```text
admit      take custody of an obligation
move       transfer custody atomically
seal       stop new custody
claim      take exclusive resolution authority
resolve    discharge, fail or restore the claimed obligation
observe    inspect the ledger
```

The canonical scope surface is:

```lua
-- commands
scope:admit_op(item_or_owned)
scope:borrow_op(item, rights, opts)
scope:move_op(item, target_scope_or_region, opts)
scope:claim_op(item, purpose)
scope:resolve_op(claim, resolution)
scope:seal_op(reason)

-- facts
scope:sealed_op()
scope:done_op()

-- diagnostics
scope:inspect_op()
```

`sealed_op` means no new custody may enter. `done_op` means the boundary has reached an accounted outcome; it does not mean success. `inspect_op` is diagnostic rather than a normal programming interface.

`Scope` does not replace `Region`.  `Region` is the atom that records ownership.
`Scope` is the compound facility that gives that ledger a practical lifetime
boundary, policy surface and two composable boundary facts.

## Authority and borrowing

Scope also exposes the first authority seam:

```lua
scope:authorise_op(item, right)
scope:borrow_op(item, rights, opts)
```

Custody is not authority.  Custody means responsibility to settle.  Authority
means permission to act through a handle.  Borrowing grants temporary authority
without moving custody.

A borrow is itself an owned obligation in the borrower scope.  It settles when
the borrower settles.  Flow endpoint byte movement is the first concrete family
of safe handles wired into this authority seam: owned inlets check write
authority, and owned outlets check read authority.

See `docs/authority-and-borrowing.md` for the detailed account.

## Movement and negotiated offers

Direct custody transfer uses `move_op`:

```lua
fibers.perform(from:move_op(item, to))
```

Negotiated transfer uses `offer_op` and `accept_op`:

```lua
fibers.perform(fibers.tensor({
  from:offer_op(stream, to, { role = 'session' }),
  to:accept_op(function(offer)
    return offer.terms and offer.terms.role == 'session'
  end),
}))
```

A rejected offer did not happen.  The filtered accept rejects that possible
world; it must not consume and discard the wrong offer.

## Settlement

On exit, a scope seals.  Sealing is not settlement.  It only stops new custody.
The policy driver then resolves remaining obligations.

Settlement runs under a claim:

```text
live root -> claim -> settlement protocol -> resolve
```

If settlement succeeds, the claim resolves with `discharge`.  If settlement
fails, the record remains visible in `failed` phase and the failure is carried in the boundary report.  See `docs/settlement.md`.

## Observation

Scope exposes boundary facts, not a lifecycle event stream:

```text
sealed_op  no new custody may enter
done_op    the boundary has reached an accounted outcome
inspect_op diagnostic snapshot derived from the Region ledger
```

`inspect_op` is for tests, tools, reports and future mirrors.  Ordinary
application code should generally compose with operations and cancellation, not
poll scope status.

## Policy

Structured concurrency is policy over the lifetime calculus, not the calculus
itself.

The default policy seals on exit, observes owned task roots concurrently, requests
cancellation after body or child failure, retires roots and reports errors.  A
supervisor policy may isolate child failure.  A future phase policy may seal at
a phase boundary, move declared carry-forward obligations, release borrows and
tomb unresolved failures.

The public shape remains the same:

```lua
fibers.scope(function(scope)
  ...
end)
```

Only the policy changes.
