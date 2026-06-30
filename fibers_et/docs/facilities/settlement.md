# Settlement

Settlement is the disciplined cleanup story beneath `Scope`, streams and
other owned facilities.

Most users do not construct settlement protocols directly.  They use options
such as `close`, `cancel`, `join` and `retire`.  Resource authors use settlement
when a value can be owned by a `Region` and needs resource-specific work before
that ownership may be released.

## The ordinary story

A scope owns work and resources.  When an owned thing is no longer needed, it
is retired.

```text
create / open / spawn
        |
        v
owned by a scope
        |
 close / cancel / retire
        |
        v
settled by the resource's protocol
        |
        v
released from ownership
```

Retirement is explicit transactional work.  It is not a garbage-collection
finalizer and it is not an unstructured callback.

## The ownership story

`Region` owns typed records.  Each record contains:

```text
item
role
children
settlement protocol
settlement name
phase
claim metadata, if claimed or failed
```

A simple live item may be moved or released.  A compound root may have
children; the root subtree moves or settles as one structure.

A scope facility retires an item by asking the region to claim the root
subtree, running the settlement protocols, then resolving the claim with
`discharge`.

```text
owned subtree
    |
    | claim_op
    v
claimed subtree
    |
    | settlement protocol Op values
    v
settlement complete
    |
    | resolve_claim_op(original_claim, { kind = 'discharge' })
    v
released subtree
```

The visible `claim_id` is diagnostic only.  The actual claim object is the
authority to finish settlement.

## Settlement laws

```text
Losing worlds do not claim, settle or release.

Claiming is committed ownership state, not a callback.

A claimed subtree cannot be transferred, released or claimed again except by the
claim authority.

Settlement protocols run as ordinary options after the claim commits.

Final release requires the original claim authority object and an explicit discharge resolution.

Protocol failure does not erase the claim.  It records an observable
failed state in the Region ledger.
```

## Failure

A settlement protocol may fail.  That failure happens after the claim has
committed, so the claim is not rolled back.

The region record remains owned and becomes:

```text
phase = "failed"
settlement_failed = true
settlement_error_message = ...
```

The item is not released.  Ordinary movement, release and duplicate settlement
remain blocked because the subtree is no longer live.

Policy code may inspect the failed record and decide what to do next.  This phase adds explicit `restore` as a resolution for retry-style policies; tomb and force-release policies remain deliberately outside this phase.

## Owned values

Advanced users and resource authors admit custom values with `fibers.Region.Owned`.
`Owned` is part of Region's advanced ownership API, not an eighth base concept.

```lua
local owned = fibers.Region.Owned.item(handle, function(ctx, record, claim)
  return handle:close_op(claim.reason)
end, {
  role = 'demo-handle',
  settle_name = 'demo-close',
})

fibers.perform(region:admit_op(owned))
```

The settlement function returns an `Op`.  Settlement may also be supplied as a small protocol table with a `name`, optional `request_op`, and required `discharge_op`.  It may perform transactional work,
wait, and compose with other options.  It must not do speculative external
cleanup while merely constructing the option.

Use `Owned.inert(item)` only when no cleanup is required.  Inert ownership is
explicit structure, not absence of a protocol.

## Authority is incremental

Ownership records determine responsibility, movement and settlement.  Authority
checks determine who may act through a handle.  The current implementation now
exposes `authorise_op` and `borrow_op`, but not every existing handle has yet
been rewritten to enforce authority for every method.

Resource authors should treat authority checks as the future direction: retained
Lua reachability should not by itself imply permission to perform sensitive
operations.  See `docs/authority-and-borrowing.md`.
