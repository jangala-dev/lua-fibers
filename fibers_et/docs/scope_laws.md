# Scope lifetime laws

`Scope` is both the ordinary lightweight container for lifetimes and the core
calculus from which richer facilities such as phases, membranes, escrow and
tombs can be built.

Ordinary code should meet it as a simple boundary:

```lua
fibers.scope(function(scope)
  local task = fibers.spawn(function() end)
end)
```

The implementation is guided by the following laws.

## Custody

A committed live obligation has exactly one custodian.

A lifetime-bearing value enters custody only by committed admission or committed
movement.  Convenience facilities such as `spawn` and safe stream acquisition
must be built on admission.

A scope is the ordinary custody boundary.  Constructors that create
lifetime-bearing values should use the current scope by default and should fail
outside a current scope unless an explicit owner is supplied.

## Sealing

A sealed scope accepts no new obligations.

Sealing is not settlement.  It prevents new admission while leaving existing
obligations to be resolved.  A scope becomes done only when its boundary has finished accounting for its
obligations.  The Region ledger remains the source of truth for owned, claimed
and failed records.

## Movement

Custody transfer is atomic.

A moved obligation is never duplicated and never ownerless.  Negotiated custody
transfer is a protocol over movement and rendezvous: an offer commits only if
the receiver accepts in the same committed world.  A rejected offer did not
happen.

## Authority

Use requires current authority.

The calculus distinguishes custody, authority, borrowing, leases and claims:

```text
custody    responsibility for an obligation
authority  permission to act through a handle
borrow     temporary authority without custody
lease      compatibility-managed temporary right
claim      exclusive authority to resolve custody
```

A borrow is itself an owned obligation in the borrower scope.  When the borrower
settles, the borrow releases its leases.  Future membrane facilities should be
built from this distinction, not added as side-channels.

## Claim and resolution

Resolution begins with an exclusive claim.

A live root may be claimed for retirement or another resolution purpose.  While a
subtree is claimed, it may not be moved, released directly, or claimed again.
Claim resolution is explicit.

The Region lifecycle is deliberately small:

```text
live     admitted and usable by the custodian
claimed  exclusively held for resolution
failed   resolution failed and remains visible
retired  discharged; no longer in the live ledger
```

Current claim resolutions are:

```text
discharge  settlement succeeded; remove the subtree from live custody
fail       settlement failed; keep the failure visible
restore    release the claim and return the subtree to live custody
```

`retired` is normally represented by absence from the Region's owned table; the
name remains part of the lifecycle so settlement can be reasoned about without
pretending that removal was an unstructured deletion.

## Settlement truth

A scope may not settle while live obligations remain unresolved.

Settlement failure is observable.  If a settlement protocol fails after its claim
commits, the owned record remains in `failed` phase with the failure attached,
and the boundary report carries the failure.  Failure to clean up is therefore
a surviving fact, not a swallowed exception.

## Observation

A lifetime system should explain why time cannot advance.

Scopes expose a small observation surface: `sealed_op`, `done_op`, and
`inspect_op`.  The Region ledger remains the source of truth for which
obligations remain, which are claimed, and which failed to settle.

## Test pressure

Tests should be grouped by law, not only by module.  A change that weakens one
of these laws should either fail a law test or change this document deliberately.
