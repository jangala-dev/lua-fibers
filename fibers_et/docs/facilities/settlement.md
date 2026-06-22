# Settlement

Settlement is the disciplined cleanup story beneath `Lifetime`, streams and
other owned facilities.

Most users do not construct settlement protocols directly.  They use options
such as `close`, `cancel`, `join` and `retire`.  Resource authors use settlement
when a value can be owned by a `Region` and needs resource-specific work before
that ownership may be released.

## The ordinary story

A lifetime owns work and resources.  When an owned thing is no longer needed, it
is retired.

```text
create / open / spawn
        |
        v
owned by a lifetime
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

A simple live item may be reassigned or released.  A compound root may have
children; the root subtree moves or settles as one structure.

A lifetime facility retires an item by asking the region to claim the root
subtree, running the settlement protocols, then settling the claim.

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
    | settle_claim_op(original_claim)
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

Final release requires the original claim authority object.

Protocol failure does not erase the claim.  It records an observable
settlement_failed state and discharges a settlement_failed lifetime event when the
caller is a Lifetime.
```

## Failure

A settlement protocol may fail.  That failure happens after the claim has
committed, so the claim is not rolled back.

The region record remains owned and becomes:

```text
phase = "settlement_failed"
settlement_failed = true
settlement_error_message = ...
```

The item is not released.  Ordinary handoff, release and duplicate settlement
remain blocked because the subtree is no longer live.

Policy code may inspect the failed record and decide what to do next.  Retry and
force-release policies are deliberately not part of this phase.

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

The settlement function returns an `Op`.  It may perform transactional work,
wait, and compose with other options.  It must not do speculative external
cleanup while merely constructing the option.

Use `Owned.inert(item)` only when no cleanup is required.  Inert ownership is
explicit structure, not absence of a protocol.

## Ownership is not access control in this phase

Ownership records determine responsibility, handoff and settlement.  This WIP
phase does not yet use ownership as an access-control check on every retained Lua
handle.  A caller that kept an old handle may still be able to call methods on
it unless that particular facility performs its own authority checks.

Future APIs may add owner-authorised handles, but the present settlement model is
about responsibility and fate, not comprehensive capability enforcement.
