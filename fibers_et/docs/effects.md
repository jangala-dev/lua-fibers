# Typed effects

A typed effect is a runtime-owned obligation carried by a candidate world.
It is not a callback and it is not a value returned to one participant.

An effect exists because the selected world committed.  If that world loses,
is abandoned by residual fallback, or fails preparation, the effect leaves
no trace.

## The basic distinction

```text
resource journal
  tentative state change installed by commit

effect
  runtime obligation entailed by the committed world

wrap
  post-commit value transformation applied inside the resumed fibre
```

For example, an ownership resource may journal:

```text
owner(resource) := B
closed(B) := true
```

and then derive the effect:

```text
settle(resource, owner = B)
```

The settlement is not returned to a participant to do later.  It belongs to the
committed world.

## Why typed?

An effect kind owns the small algebra for one family of obligations:

```text
name      diagnostic name
key       extracts the obligation key
merge     combines duplicate obligations or rejects conflicts
prepare   validates and creates dischargeable work
discharge   performs or records the prepared work
order     relative discharge order
failure   failure policy, currently fatal
```

This lets different obligations have different rules.  A wakeup effect may
merge ten requests for the same wait set into one wake.  An outbox append should
not merge two different message identifiers.  A cache invalidation kind may
merge row invalidations into a partition invalidation.  An audit kind may reject
conflicting records with the same idempotency key.

An untyped after-commit callback cannot express these rules without smuggling
domain logic into arbitrary code.

## Public shape

Define a effect kind with `fibers.kernel.effect.kind`:

```lua
local EffectKind = require('fibers.kernel.effect.kind')

local KickKind = EffectKind.new {
  name = 'example.kick',

  key = function(payload)
    return payload.worker_id
  end,

  merge = function(a, _b)
    -- One kick is enough for the same worker.
    return a
  end,

  prepare = function(_rt, payload)
    return {
      kind = KickKind,
      key = payload.worker_id,
      payload = payload,
      discharge = function(rt, entry, log)
        if rt.host and rt.host.kick_worker then
          rt.host.kick_worker(entry.key, entry.payload)
        end
      end,
    }
  end,
}

local function kick(worker_id)
  local c, err = KickKind:of { worker_id = worker_id }
  if not c then error(err and err.message or tostring(err), 2) end
  return c
end
```

Use it in an option with `Op.emit`:

```lua
local Op = require('fibers.atoms.op')

local op = Op.emit(kick('delivery-worker'))
```

`Op.emit` only accepts typed effect objects.  Plain Lua functions, strings
and tables are rejected.

## Commit order

For a selected world, the runtime order is:

```text
prepare resource commits and effects
apply prepared resource commits
discharge prepared effects
settle selected and lost nack obligations
resume selected fibres with raw values and post-commit transformers
apply wraps inside perform
```

This order is the reason `emit` and `wrap` are different.

`emit` is interpreted by trusted runtime machinery before selected participants
resume.  `wrap` runs in participant code after the transaction has committed.
A wrap may perform another transaction, and a wrap failure does not roll back the
already committed transaction.

## Merge and conflict

Effects are stored in sets keyed by effect kind and the kind-specific
key.

If two obligations have different keys, both may survive:

```text
KickWorker(A)
KickWorker(B)
```

If they have the same key, the kind decides whether they merge:

```text
KickWorker(A)
KickWorker(A)
  -> KickWorker(A)
```

or conflict:

```text
Audit(event_id=7, amount=10)
Audit(event_id=7, amount=20)
  -> candidate rejected
```

The merge function should be pure.  It may return a merged payload or reject the
candidate with an error record.

## Preparation and discharge

`prepare` runs after a candidate world has been selected but before resource
commits are applied.  It should validate the obligation and return a prepared
record containing a `discharge` function.

Preparation must be side-effect-free.  It may refuse the candidate.  It should
not send messages, wake schedulers, mutate resources, write to external systems,
yield, call `perform`, or call `run`/`step`.

`discharge` runs after resource commits have been applied.  In this prototype,
discharge failure is fatal.  That is deliberate: once resource journals have
committed, the runtime cannot safely pretend that the world did not commit.

## Exactly-once scope

The current guarantee is in-process and commit-local:

```text
if a world is selected and committed,
each prepared effect entry in that world is discharged once by that commit
```

It is not a crash-durable or distributed exactly-once guarantee.

For an external system, the recommended pattern is:

```text
resource journal installs durable state
effect installs or records a durable idempotent obligation
external delivery retries outside the transaction
```

Examples include an outbox row, saga step, email job, payment capture request,
worker kick, cache invalidation record, audit event or metering record.

## Common uses

Typed effects are useful when committed state entails runtime work:

```text
transactional outbox discharge
scheduler wakeups
task admission and post-commit spawn
cache and materialised-view invalidation
audit, metering and security records
resource finalisation
lease release and timer cancellation
workflow or saga step registration
```

The common pattern is:

```text
work must not happen speculatively
work must not be owned by one participant continuation
losing alternatives must leave no trace
duplicates must be merged or rejected by domain-specific rules
```

## Relation to resources

A resource may derive effects during preparation from the final committed
record.  An ownership resource can do this for settlement: ownership movement and
close state are resource journal entries; settlement is a effect derived
from the final committed ownership state.

Resources can also expose public options that simply emit effects.  The
right choice depends on whether the obligation is directly requested by user code
or entailed by resource state.
