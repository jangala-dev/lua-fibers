# Eventful Transactions kernel

This bundle is the model-first Eventful Transactions kernel after the
`Protocol.Link` consolidation.

The public boundary is deliberately small:

```lua
local Op       = require('et.op')       -- inert operation syntax
local Protocol = require('et.protocol') -- Link, Values, Effect
local Machine  = require('et.machine')  -- attempt/world/commit semantics
local Runtime  = require('et.runtime')  -- execution and scheduling
```

## Core shape

```text
Op        creates claims
Protocol  defines the Link protocol for primitives
Machine   searches, prepares, and commits through Link
Runtime   schedules attempts and delegates external watching to the host
Resources implement Link participants
```

The machine/primitive boundary is the six-message `Protocol.Link` protocol:

```text
snapshot(resource)
initial(resource, snapshot)
claim(resource, snapshot/fragment, claim)
merge(resource, merge_request)
prepare(resource, fragment)
commit(resource, prepared)
```

External readiness is represented as blocked claim data. Runtime host integration
watches and unwatches those waits; wait publication is not a Link verb.

Built-in resources are expressed directly as:

```lua
Protocol.Link.resource { ... }
```

## Operations

Application code builds inert operations. The primitive form is `Op.claim`:

```lua
Op.claim(resource, 'access', request)
Op.claim(resource, 'open_claim', request)
Op.claim(resource, 'await', request)
```

The older ergonomic constructors are aliases over the same claim syntax:

```lua
Op.access(resource, request)
Op.open_claim(resource, request)
Op.await(resource, request)
```

Linear obligations use the general obligation form:

```lua
Op.with_obligation('admission', payload, function(ref)
  return ...
end)
```

`Op.with_nack(function(nack) ... end)` is now a settlement-obligation instance;
`nack` is `Op.nack(ref)`, an obligation observation operation.

Bundled resources expose ergonomic constructors:

```lua
local Cell    = require('et.resources.cell')
local Queue   = require('et.resources.queue')
local Channel = require('et.resources.channel')

cell:get_op(Op)
cell:set_op(Op, value)
cell:update_op(Op, fn)

queue:push_op(Op, value)
queue:pop_op(Op)
queue:await_nonempty_op(Op)
queue:pop_wait_op(Op)

channel:put_op(Op, ...)
channel:get_op(Op)
```

## Invariants

```text
An OpExpr is inert.
A Frontier is snapshot-indexed.
Proof search never sees stale evidence.
A CandidateWorld contains only selected evidence.
Product lanes contribute Link fragments, not inherited base evidence.
or_else fallback requires an AbsenceCertificate.
CommitCertificate is built only from selected evidence.
Only CommitCertificate.apply mutates resources.
Only normalised split effect logs are published.
wrap is never a transaction effect.
Occurrence identity is canonical and stable.
Published obligations settle exactly once as selected, lost or withdrawn.
Frontier refresh never forgets published obligations from the same live attempt.
Search-phase callbacks may not perform or spawn.
```

## Dependency direction

```text
et.op         pure syntax
et.protocol   Link, Values, Effect
et.machine    attempt -> world -> commit
et.runtime    scheduling and host/runtime integration
et.resources  concrete Link participants
```

`Op` does not depend on `Protocol`, `Machine`, or `Runtime`. `Protocol` does
not depend on `Machine` or `Runtime`. Resources require `et.protocol`, never
`et.machine` or `et.runtime`. Tests may reach into machine organs directly.

## Running tests

```sh
texlua tests/run.lua
```

Expected final line:

```text
all tests: ok
```
