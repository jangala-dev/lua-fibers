# Facility authoring

Most extensions should be ordinary Lua modules which compose supported options and resources. They should not depend on `fibers.internal`.

## Shape of a facility

A facility normally:

1. owns one or more supported resources;
2. exposes methods ending in `_op` which construct composable options;
3. mirrors its principal `_op` methods with plain direct methods which perform
   those options;
4. keeps the option construction path inert and does not call `perform` inside an `_op` method;
5. uses `each`, `together`, `choice`, sequencing and mapping to state its laws;
6. leaves fibre and lifetime structure to callers unless custody is intrinsic to the facility.

```lua
local Counter = require('fibers.resource.counter')
local perform = require('fibers.perform')

local Latch = {}
Latch.__index = Latch

function Latch.new(count, name)
  return setmetatable({ remaining = Counter.new(count or 0, name) }, Latch)
end

function Latch:count_down_op(amount)
  return self.remaining:take_op(amount or 1)
end

function Latch:wait_op()
  return self.remaining:zero_op()
end

function Latch:count_down(amount)
  return perform(self:count_down_op(amount))
end

function Latch:wait()
  return perform(self:wait_op())
end
```

## Naming

Use `_op` for methods which construct composable options. For each principal
suspending or transactional operation, normally expose a plain method with the
same stem as the direct on-ramp:

```text
queue:get()       perform the operation directly
queue:get_op()    return the operation for composition
```

The plain method should perform the corresponding `_op` method rather than
duplicate its implementation. Plain methods may therefore suspend and commit
transactional state. Methods which are genuinely immediate remain useful for
local inspection and construction, but their names should not imply a stronger
non-suspension rule for the whole plain-method surface.

## Completed closure for host-backed facilities

A public `closed_op` must observe structural completion, not merely the first
host-level terminal signal. For a driver-backed facility it becomes ready only
after all of the following have settled:

- the host handle or external operation has reached its terminal state;
- the facility's private driver body has returned;
- the driver's private Scope has retired its children;
- reactor registrations and host holds have retired;
- any retained closure failure is represented to the caller.

Built-in facilities use the shared internal `closed_after_driver_op` rule where
this shape applies. Third-party facilities should express the same law using
public task, Scope and resource operations. Publishing a completion event before
the private driver subtree has retired is not sufficient.

## Normative callback discipline

Facilities must place each callback in one of three phases.

| Phase | Facility callbacks | Requirements |
|---|---|---|
| Speculative search | guards, `map`, `and_then`, transition rules, effect `key` and `merge` | Deterministic, non-yielding and replayable. No external mutation, performing, spawning or irreversible work. |
| Committed-world effect protocol | effect `prepare` and `discharge` | `prepare` is pure and may be called repeatedly or discarded. It returns either a structured refusal or a prepared record with `discharge`. `discharge` runs once after state installation. |
| Participant continuation | `wrap` | Runs after commit in the resumed fibre. It may perform, spawn and interact with the outside world. |

`prepare` must not reserve host capacity or acquire an external resource. It may inspect only the effect payload, captured runtime configuration and managed facts already represented by the candidate. A refusal based on untracked volatile host state is invalid because it could admit an `or_else` fallback without a revalidatable proof. Model such capacity or readiness as a managed resource, then put the irreversible host action in `discharge`.

Effect identity is `(EffectKind, key)` using raw Lua identity. Do not stringify keys in an effect kind. Values of different types remain distinct; table and userdata keys use object identity; `nil` is supported; NaN is not. `merge` is called only for effects of the same kind with the same raw key.

Use a typed effect when the work belongs to the committed world. Use `wrap` when it belongs to one resumed participant.

## Composition before new mechanisms

Prefer:

- Channel for application communication;
- Cell for replaceable state;
- Counter for quantities and epochs;
- Index for ordered witnessed collections;
- Rendezvous for synchronous exchange;
- Machine for genuinely serial state relations;
- Pulse for coalescing notification;
- Scope and Task for work held in custody;
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
