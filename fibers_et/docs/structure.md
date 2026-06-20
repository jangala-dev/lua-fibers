# Repository structure

`fibers` is arranged in layers.  The public convenience module remains
`require('fibers')`, but the tree itself makes the role of each module clear.

```text
fibers.lua
  public convenience facade

fibers/base.lua
fibers/base/
  the public base kit: Op, Cell, Channel, Source, Region, Task, Effect and
  advanced Owned admission values

fibers/facility.lua
fibers/facility/
  compound facilities built from the base kit, such as Sleep, Lifetime and policies

fibers/host.lua
fibers/host/
  host adapter helpers, HostHandle contracts, optional fd handles, and standalone host implementations

fibers/runner.lua
  standalone runner that drives Runtime:run with a host adapter

fibers/kernel.lua
fibers/kernel/
  the eventful transaction engine: runtime, transaction net, resource frontier,
  wait interests, protected calls and effect machinery

fibers/internal/
  private implementation details and invariants
```

The placement rule is:

```text
base       if it is one of the few nouns that explains the library
facility   if it is useful user-facing machinery built from the base
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
local Cell = require('fibers.base.cell')
local Sleep = require('fibers.facility.sleep')
local Lifetime = require('fibers.facility.lifetime')
local Runtime = require('fibers.kernel.runtime')
local PureHost = require('fibers.host.pure')
local LuaJITHost = require('fibers.host.luajit_linux')
local NixioHost = require('fibers.host.nixio')
```

New modules should be placed by role rather than convenience.  In particular,
`fibers/base` is intentionally small: adding a base noun should be rare.

## Structural claims and settlement

Regions own typed ownership records rather than bare objects.  Admission records
the item, its Op-valued settlement protocol, its role, and any child ownership
edges.  Region's general lifecycle algebra is:

```text
admit:
  owner + item + settlement protocol + children

claim:
  claim the owned subtree for a purpose
  prevent incompatible handoff, release or duplicate claims

settle:
  validate the claim authority object
  atomically release the claimed subtree
```

There is no implicit settlement protocol stack and no method probing fallback.  A value may
be admitted only as an `Owned` value, or as a handle whose constructor installed
a default settlement protocol.  The inert protocol is therefore explicit
structure, not absence of cleanup.

Settlement is a multi-commit protocol, but it is not a second public algebra.
A facility such as `Lifetime` claims the subtree, discharges a typed spawn effect
for a settlement driver, and the driver performs ordinary `Op` protocols before
performing one atomic `settle_claim`.  A visible `claim_id` is diagnostic only;
settlement requires the original claim object produced by the committed claim.

If a settlement protocol fails after the claim has committed, the owned subtree
is not silently released and the claim is not rolled back.  The affected records
become `settlement_failed`, expose a failure message, and Lifetime discharges a
`settlement_failed` event for policy code.

Compound resources such as host streams are admitted as trees.  The stream root
has a stream settlement protocol, while its flows, endpoints and pump tasks have
their own protocols.  Handoff moves the whole live root subtree; contained
children are not reassigned directly by default.

This phase treats ownership as responsibility and settlement authority, not as a
comprehensive access-control check on every retained Lua handle.  See
`docs/facilities/settlement.md` for the full settlement account.
