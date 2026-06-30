# Settlement

Settlement is the disciplined discharge of custody.  It is not garbage
collection, finalisation or an unstructured cleanup callback.

A scope or other policy retires an owned root by claiming it, running its
settlement protocol, and resolving the claim.  If settlement fails, the failure
remains visible in the lifetime ledger.

For lower-level resource-author details, see `docs/facilities/settlement.md`.

## Shape

```text
live obligation
    |
    | claim_op
    v
claimed obligation
    |
    | settlement protocol
    v
settlement result
    |
    | resolve_op / resolve_claim_op
    v
discharged, failed, or restored
```

The visible `claim_id` is diagnostic.  The claim object produced by the committed
claim operation is the authority to resolve the claim.

## Settlement protocol

A settlement protocol is resource-specific work expressed as ordinary `Op`
values.  The normalised table shape is:

```lua
{
  name = 'resource-close',

  request_op = function(ctx, record, claim)
    -- optional: ask the resource to start shutting down
  end,

  discharge_op = function(ctx, record, claim)
    -- required: attempt to discharge custody
  end,
}
```

Function-style settlement protocols are still adapted internally, but resource
authors should prefer the table shape when a resource has more than one
settlement phase.

A protocol must not do irreversible external work merely by being constructed.
Its work belongs in returned `Op` values and should happen only when the relevant
world commits.

## Claim and resolve

The conceptual pair is:

```text
claim -> resolve
```

Supported current resolutions are:

```text
discharge  settlement succeeded; remove the subtree from live custody
fail       settlement failed; keep the failure visible
restore    release the claim and return the subtree to live custody
```

Settlement policy is a compound over this pair:

```text
claim the root
run settlement protocols
resolve with discharge or fail
```

The raw helper for compound authors is `fibers.internal.settlement.retire_item_op`; ordinary user code should normally rely on `fibers.scope` or `fibers.run` to drive it.

## Failure

A settlement failure occurs after the claim has committed.  The implementation
therefore must not pretend that nothing happened.

On failure, the affected record remains owned and observable:

```text
phase = "failed"
settlement_failed = true
settlement_error_message = ...
```

A failed settlement should be reported alongside any body failure or child
failure that led to scope exit.  Future mirror facilities may derive richer
observations from the Region ledger and boundary reports.

This is the key law:

```text
failure to clean up is surviving lifetime state
```

## Policy

Settlement policy sits above the calculus.  The default nursery-like policy
observes owned task roots concurrently, cancels siblings after body or child
failure, and then retires all remaining roots.  A supervisor policy may isolate
child failure.  A future phase policy may move declared
carry-forward obligations, release borrows, and tomb unresolved failures.

The calculus should remain smaller than any one policy:

```text
admit
move
claim
resolve
seal
observe
```

## Future tombs

A tomb is not yet a public facility.  The design pressure is clear: a failed
settlement may need a place to remain owned without blocking the original scope
forever.

A tomb would be custody of unresolved settlement.  It should be introduced only
when failed records, reports and policy have made the need precise.
