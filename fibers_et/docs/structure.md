# Repository structure

`fibers` is arranged in layers.  The public convenience module remains
`require('fibers')`, but the tree itself makes the role of each module clear.

```text
fibers.lua
  public convenience facade

fibers/atoms.lua
fibers/atoms/
  the public atom kit: Op, Scalar, Rendezvous, Index, Counter, Keyed,
  Lease, Source, Region, Effect and advanced Owned admission values

fibers/*.lua
  compound public facilities built from the atom kit, such as Task, Sleep,
  Scope, Queue, Pool, Flow, Stream and scope policy helpers

fibers/host.lua
fibers/host/
  host adapter helpers, HostHandle contracts, optional fd handles, and standalone host implementations

fibers/runner.lua
  standalone runner that drives Runtime:run with a host adapter

fibers/kernel.lua
fibers/kernel/
  the eventful transaction engine: runtime, transaction net, resource protocol,
  managed validity facts, wait interests, protected calls and effect machinery

fibers/internal/
  private implementation details and invariants
```

The placement rule is:

```text
atoms      if it is one of the few nouns that explains the library
top-level  if it is useful user-facing machinery built from the atoms
host       if it bridges Runtime waits to process-level blocking or polling
runner     if it drives a Runtime as a standalone application
kernel     if it is eventful-transaction engine machinery
internal   if direct use should not be relied on
```

Ordinary code should normally use:

```lua
local fibers = require('fibers')
```

Library authors may import a layer explicitly:

```lua
local Scalar = require('fibers.atoms.scalar')
local Sleep = require('fibers.sleep')
local Scope = require('fibers.scope')
local Runtime = require('fibers.kernel.runtime')
local PureHost = require('fibers.host.pure')
local LuaJITHost = require('fibers.host.luajit_linux')
local NixioHost = require('fibers.host.nixio')
```

New modules should be placed by role rather than convenience.  In particular,
`fibers/atoms` is intentionally small: adding an atom should be rare.

The current documentation split is:

```text
user guide        docs/scope.md and facility documents
laws             docs/scope_laws.md and docs/kernel/resource-laws.md
design account   docs/lifetime-calculus.md and docs/future-compounds.md
resource authors docs/kernel/resources.md and docs/facilities/settlement.md
```

## Structural claims and settlement

Regions own typed ownership records rather than bare objects.  Admission records
the item, its settlement protocol, its role, and any child ownership edges.
Region's lifecycle algebra is:

```text
admit:
  owner + item + settlement protocol + children

move:
  atomically transfer a live root to another Region

claim:
  claim the owned subtree for a purpose
  prevent incompatible movement, release or duplicate claims

resolve:
  discharge, fail or restore the original claim
```

There is no implicit settlement protocol stack and no method probing fallback.  A
value may be admitted only as an `Owned` value, or as a handle whose constructor
installed a default settlement protocol.  The inert protocol is therefore
explicit structure, not absence of cleanup.

Settlement is a multi-commit protocol, but it is not a second public algebra.  A
facility such as `Scope` claims the subtree, then runs ordinary `Op` protocols
under a masked settlement strategy before performing one explicit resolution.  A
visible `claim_id` is diagnostic only; settlement requires the original claim
object produced by the committed claim.

If a settlement protocol fails after the claim has committed, the owned subtree
is not silently released and the claim is not rolled back.  The affected records
enter `failed` phase, expose a failure message, and the boundary report carries
the failure.

Compound resources such as host streams are admitted as trees.  The stream root
has a stream settlement protocol, while its flows, endpoints and pump tasks have
their own protocols.  Movement transfers the whole live root subtree; contained
children are not moved directly by default.

Safe resource handles should use scope authority before performing sensitive
operations.  The authority seam is `authorise_op`; temporary authority without
custody is represented by `Borrow`, which is itself an owned obligation.  This
work is intentionally incremental: not every existing handle has yet been
rewritten to enforce authority for every method.  See `docs/authority-and-borrowing.md`
and `docs/settlement.md`.

## Managed validity

`fibers.kernel.validity` is kernel machinery for resource authors.  It provides
the managed facts used to make bounded search and absence proofs safe to reuse.
Ordinary application code should normally meet these through public resources
such as Scalar, Source, Region, Scope and Stream, not by constructing validity
facts directly.

`fibers.kernel.frontier` is now the low-level generation-stamp substrate used by
managed validity capabilities.  It is not a public resource-authoring API.


## Policy and supervisor placement

Launch policies are user-facing coordination machinery, not atoms and not
kernel machinery.  They live at top level as `fibers.policy`.  Future
supervisor-style APIs should follow the same rule:

```text
fibers.policy      scope policy constructors such as nursery
fibers.supervisor  user-facing supervision facility, if it becomes a structure
                  users instantiate directly
```

If a future supervisor is merely another scope policy, it should be a
constructor under `fibers.policy`.  If it is a runtime object with its own state,
children, restart strategy and observations, it should be a top-level facility
`fibers.supervisor` built over `Scope`, `Task`, `Region`, `Source` and
`Effect`.
