# Facility authoring

Most extensions should be ordinary Lua modules which compose supported options and resources. They should not depend on `fibers.internal`.

## Shape of a facility

A facility normally:

1. owns one or more supported resources;
2. exposes methods ending in `_op`;
3. returns inert options without calling `perform` internally;
4. uses `all`, `tensor`, `choice`, sequencing and mapping to state its laws;
5. leaves fibre and lifetime structure to callers unless ownership is intrinsic to the facility.

```lua
local fibers = require('fibers')
local Scalar = require('fibers.scalar')

local Latch = {}
Latch.__index = Latch

function Latch.new(count)
  return setmetatable({ state = Scalar.new(count or 0, 'latch') }, Latch)
end

function Latch:wait_op()
  local function loop()
    return self.state:snapshot_op():and_then(function(snapshot)
      if snapshot.value == 0 then
        return fibers.always(true)
      end
      return self.state:changed_op(snapshot.version):and_then(loop)
    end)
  end
  return loop()
end
```

## Naming

Use `_op` for methods which construct composable options. Reserve plain methods for immediate inspection or local construction which cannot suspend or commit transactional state.

## Callback discipline

Callbacks executed during search must be deterministic, non-yielding and free of irreversible side effects. Put committed external work in a typed effect or in `wrap`, according to whether the work belongs to the committed world or to one resumed participant.

## Composition before new mechanisms

Prefer:

- Channel for application communication;
- Scalar for state machines;
- Pulse for coalescing notification;
- Scope and Task for owned work;
- the resource toolkit for allocation and compatibility laws.

A new public facility should have a distinct law, compose with the option algebra, and remove recurring application complexity. A convenience which merely saves a few lines is usually better as a recipe.

## Worked recipes

The repository contains complete examples under `examples/recipes/`:

- token-bucket rate limiter;
- countdown latch;
- priority queue;
- resource pool.

These recipes are tested but are not part of the installed version 1 surface.

## Closed kernel protocol

The kernel IR and store are implementation details under `fibers.internal.kernel`. New trusted resource programmes require repository-level review and are covered by `../contributing/trusted-resource-programmes.md`.
