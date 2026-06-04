# Eventful Transactions algebra after Protocol.Link

The primitive/machine algebra is expressed by `Protocol.Link`.

A primitive receives claims and owns the fragment algebra for its resource. The
machine asks six questions only:

```text
snapshot
initial
claim
merge
prepare
commit
```

## Claims

The single primitive operation form is a claim:

```lua
Op.claim(resource, 'access',     { tag = 'set', value = 1 })
Op.claim(resource, 'await',      { tag = 'nonempty' })
Op.claim(resource, 'open_claim', { tag = 'send', values = Values.pack('x') })
```

`Op.access`, `Op.await`, and `Op.open_claim` are aliases that construct the same
claim syntax. At the `Protocol.Link` boundary, claims are data:

```lua
{ kind = 'access',     request = { tag = 'set', value = 1 } }
{ kind = 'await',      request = { tag = 'nonempty' } }
{ kind = 'open_claim', request = { tag = 'send', values = Values.pack('x') } }
```

## Fragments

Fragments are opaque to the machine. They are tentative primitive-local worlds.
A cell fragment may record a pending value change. A queue fragment may record a
new item sequence. A channel fragment may record open claims that become complete
when a later merge request supplies compatible peers.

## Merge

`merge` is the primitive composition question. The request is explicit data:

```lua
{ kind = 'coexist', fragments = { left, right } }
{ kind = 'extend',  base = prefix, fragments = { next } }
{ kind = 'project', base = common, fragments = { branch } }
{ kind = 'complete', open_claims = { a, b } }
```

The primitive decides whether the request yields a merged fragment, claim
completions, blocked dependencies, conflict, stale evidence, or fatal rejection.
The machine never inspects fragment internals.

## Commit

`prepare` certifies that a fragment is still valid against the current resource
state and returns a prepared commit plus effects. `commit` applies that prepared
commit.

The result is:

```text
Op creates claims.
Protocol defines Link.
Machine judges worlds through Link.
Runtime schedules and watches external readiness through the host.
Resources own their fragment algebra.
```


## Linear obligations

`with_nack` is not a separate machine model. It is an instance of the general
linear obligation combinator:

```lua
Op.with_obligation(kind, payload, function(ref)
  return protected_tx
end)
```

The commit certificate accounts for every published obligation exactly once as
selected, lost, withdrawn, or discharged. `Op.with_nack(f)` constructs a
`settlement` obligation and passes `f` an `Op.nack(ref)` observation operation.
