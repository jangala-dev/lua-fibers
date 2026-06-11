# Repository structure

`fibers` is arranged in layers.  The public convenience module remains
`require('fibers')`, but the tree itself makes the role of each module clear.

```text
fibers.lua
  public convenience facade

fibers/base.lua
fibers/base/
  the public base kit: Op, Cell, Channel, Source, Region, Task and Effect

fibers/facility.lua
fibers/facility/
  compound facilities built from the base kit, such as Lifetime and policies

fibers/kernel.lua
fibers/kernel/
  the eventful transaction engine: runtime, solver, resources, commit plans,
  wait interests, observation journals, protected calls and consequence machinery

fibers/internal/
  private implementation details and invariants
```

The placement rule is:

```text
base       if it is one of the few nouns that explains the library
facility   if it is useful user-facing machinery built from the base
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
local Lifetime = require('fibers.facility.lifetime')
local Runtime = require('fibers.kernel.runtime')
```

New modules should be placed by role rather than convenience.  In particular,
`fibers/base` is intentionally small: adding a base noun should be rare.
