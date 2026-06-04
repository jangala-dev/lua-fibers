# Protocol.Link: the machine/primitive boundary

`Protocol.Link` is the narrow semantic boundary between the ET machine and
transactional primitives.

The machine sends six messages:

```text
snapshot(resource)
initial(resource, snapshot)
claim(resource, snapshot/fragment, claim)
merge(resource, merge_request)
prepare(resource, fragment)
commit(resource, prepared)
```

A claim is data. `Op.claim(resource, kind, request)` is the single primitive
operation form; `Op.access`, `Op.await`, and `Op.open_claim` are aliases.
At the Link boundary the machine sends:

```lua
{ kind = 'access',     request = { tag = 'pop' } }
{ kind = 'await',      request = { tag = 'nonempty' } }
{ kind = 'open_claim', request = { tag = 'send', values = Values.pack('x') } }
```

`merge` is one question, represented by one request table. The machine does not
call primitive-local composition callbacks. It asks whether a set of tentative
fragments can become one fragment and receives either a fragment, completions,
blockage, conflict, stale, or fatal result.

```lua
{ kind = 'coexist', fragments = { left, right } }
{ kind = 'extend',  base = prefix, fragments = { next } }
{ kind = 'project', base = common, fragments = { branch } }
{ kind = 'complete', open_claims = { send, recv } }
```

Open claims are ordinary fragment contents. A channel is not special to the
machine: a send claim and receive claim become complete when the channel accepts
a `complete` merge request and returns assignments for the claims it closes.

External readiness is not a Link verb. A primitive reports a blocked claim with
semantic dependencies; the runtime/host layer watches and unwatches those waits.

Built-in resources implement the boundary directly with:

```lua
Protocol.Link.resource { ... }
```

The relationship is:

```text
Op        creates claims
Protocol  defines Link messages and resource construction
Machine   searches, prepares, and commits through Link
Runtime   schedules attempts and delegates external watching to the host
Resources own their local fragment algebra
```

`tests/test_protocol_link.lua` contains transcript-style tests that exercise
cell, queue, and channel through Link.
