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
  compound facilities built from the base kit, such as Sleep, Lifetime and policies

fibers/host.lua
fibers/host/
  host adapter helpers and optional standalone host implementations

fibers/runner.lua
  standalone runner that drives Runtime:run with a host adapter

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
local NixioHost = require('fibers.host.nixio_linux')
```

New modules should be placed by role rather than convenience.  In particular,
`fibers/base` is intentionally small: adding a base noun should be rare.
