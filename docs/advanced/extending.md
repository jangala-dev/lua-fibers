# Extending Fibers

Most extensions should be ordinary Lua modules which compose supported options and resources. They should not depend on `fibers.internal`.

Begin with the public facilities in [Resources](../guide/resources.md). This document covers the point at which a reusable application module becomes a transactional facility or trusted extension.

## Shape of a facility

A facility normally:

1. owns one or more supported resources;
2. exposes methods ending in `_op` which construct composable options;
3. mirrors its principal `_op` methods with plain direct methods which perform
   those options;
4. keeps the option construction path inert and does not call `perform` inside an `_op` method;
5. uses `each`, `together`, `choice`, sequencing and mapping to state its laws;
6. leaves fiber and lifetime structure to callers unless custody is intrinsic to the facility.

```lua
local Counter = require('fibers.resource.counter')
local fibers = require('fibers')

local Latch = {}
Latch.__index = Latch

function Latch.new(count)
  return setmetatable({ remaining = Counter.new(count or 0) }, Latch)
end

function Latch:count_down_op(amount)
  return self.remaining:take_op(amount or 1)
end

function Latch:wait_op()
  return self.remaining:zero_op()
end

function Latch:count_down(amount)
  return fibers.perform(self:count_down_op(amount))
end

function Latch:wait()
  return fibers.perform(self:wait_op())
end
```

## Method naming

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
- reactor registrations and outstanding host acquisitions have retired;
- any retained closure failure is represented to the caller.

Built-in facilities use the shared internal `closed_after_driver_op` rule where
this shape applies. Third-party facilities should express the same law using
public task, Scope and resource operations. Publishing a completion event before
the private driver subtree has retired is not sufficient.

## Normative callback discipline

Facilities must place each callback in one of three phases.

| Phase | Facility callbacks | Requirements |
|---|---|---|
| Speculative search | guards, `map`, transition rules, effect `key` and `merge` | Deterministic, non-yielding and replayable. No external mutation, performing, spawning or irreversible work. |
| Candidate-world effect protocol | effect `prepare` and `discharge` | `prepare` is pure and may be called repeatedly or discarded. It returns either `Effect.reject(reason)` or a prepared record with `discharge`. Malformed returns are contract errors. `discharge` runs once after state installation. |
| Participant continuation | `wrap` | Runs after commit in the resumed fiber. It may perform, spawn and interact with the outside world. |

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

## Closed executable-leaf protocol

The public Op graph is executed directly. Trusted primitive leaves and the transactional store remain implementation details under `fibers.internal`. New leaf kinds or trusted transition behaviour require repository-level review under the trusted-authoring contract below.


## Ordered finite-map selection

Ordered `Index` entries use `(rank, sequence)` as their complete semantic order.
Insertion sequences are allocated transactionally, so constructing an Option has
no ordering consequence. They increase with committed Index evolution; imported
entries must provide unique `(rank, sequence)` pairs. Resource keys and their
textual presentation do not participate in ordering.


## Committed effects

Effects are the extension boundary for irreversible work which belongs to a committed world.

Effects represent typed obligations which belong to a candidate world and are discharged only if that world commits.

Most application code encounters effects through tasks, interruption and host-backed facilities. This document is for facility authors and advanced users.

### Why effects exist

Some selected worlds require an irreversible action:

- start an admitted task;
- deliver an interruption;
- register host readiness;
- launch a process;
- update a host facility.

Performing that work while merely exploring an alternative would be incorrect. Fibers therefore separates speculative description from committed discharge.

### Constructing an effect kind

```lua
local Effect = require('fibers.effect')

local kind = Effect.kind({
  name = 'example.publish',
  key = function(payload)
    return payload.destination
  end,
  merge = function(a, b)
    return combine(a, b)
  end,
  prepare = function(runtime, payload)
    return {
      discharge = function()
        publish(payload)
      end,
    }
  end,
})
```

Create an effect value with:

```lua
local effect = Effect.of(kind, payload)
```

Select it in an option with:

```lua
Op.emit(effect)
```

### Kind identity

Effect kinds are identified by their kind objects, not by textual names. The name is diagnostic.

The kind defines how payloads are keyed, combined and prepared.

### Keying and merging

Effects of one kind may share a key and merge into one committed obligation.

Keying and merging are speculative callbacks. They must be deterministic, non-yielding and free of external effects.

A merge may reject incompatible obligations only by returning `Effect.reject(reason)`. Rejection invalidates that candidate world; it does not partially discharge either obligation. Returning `nil` or another malformed value is a trusted-authoring contract error rather than a semantic conflict. An exception raised by `key`, `merge` or `prepare` is likewise an authoring failure and does not cause search to backtrack; Fibers-generated phase violations retain their more specific `phase_error` classification.

### Preparation

Preparation runs after candidate validation but before managed state is installed.

It must remain pure. It may:

- validate the complete merged payload;
- calculate a discharge plan;
- reject the candidate explicitly with `Effect.reject(reason)`;
- capture immutable values needed after commitment.

It must not:

- mutate the host;
- reserve an external resource;
- spawn or perform;
- yield;
- rely on rollback of ordinary Lua effects.

### Discharge

Discharge runs after managed state has committed.

It performs the irreversible action described by the prepared plan.

A discharge failure is fatal to the Runtime because the managed state commit cannot be rolled back safely. Effect authors should keep discharge small and effectively infallible after successful preparation.

### Ordering

Effects are grouped by kind and key according to their definitions. Distinct effect kinds are discharged in deterministic first-occurrence order.

Fibers does not provide global effect priorities. External actions which must be inseparable or precisely ordered should form one compound effect kind.

### Built-in effects

Fibers uses effects for:

- Task admission and committed spawning;
- interruption delivery;
- host reactor and I/O obligations;
- selected resource notifications.

Task admission illustrates the law clearly: a dormant Task whose admission option loses never starts its body.

### Defeat obligations

Attach an effect to the defeat of one entered option occurrence with:

```lua
option:on_defeat(effect)
```

The effect is discharged if an incompatible competitor commits after the occurrence was entered.

Defeat does not mean:

- `Retry`;
- incomplete bounded search;
- an `or_else` fallback becoming eligible;
- a branch which was never entered;
- a locally rejected candidate before a competing commit.

Use defeat obligations only where the application or facility genuinely needs a committed consequence of losing one entered competition.

### Callback phases

| Phase | Examples | May affect host? |
|---|---|---|
| speculative search | `map`, `guard`, key, merge | no |
| committed preparation | `prepare` | no |
| committed discharge | discharge plan | yes |
| participant continuation | `wrap` | yes |

See [Execution and observability](execution-and-observability.md) and [The option algebra](option-algebra.md).

### Testing an effect kind

Tests should establish:

- losing alternatives never discharge;
- duplicate compatible obligations merge as specified;
- incompatible obligations reject the candidate;
- preparation failure leaves managed and host state unchanged;
- discharge observes committed managed state;
- exact key identity is preserved;
- defeat obligations follow occurrence semantics;
- bounded search does not duplicate preparation or discharge.


## Trusted primitive resource authoring

Most facilities should be assembled from existing resources. Code which adds executable leaves or trusted transition behaviour enters the following kernel-extension contract.

The public `Op` graph is the executable operation representation. Ordinary
library authors should compose public resources and `Op` combinators. This
document is for trusted contributors adding a primitive through
`fibers.resource.authoring`.

The portable trusted vocabulary is deliberately small:

```text
Location
inspect rule | change rule
exchange rule
```

Patches and outcomes are data returned by state rules. Effects remain part of
the operation algebra, and host publication remains part of the embedding
boundary.

### Boundary

A facility must not implement search, branch exhaustion, `Retry`, `Unknown`,
product visibility, rollback, candidate validation or commit. Those are kernel
rules.

Only `fibers.resource.authoring` constructs managed locations and executable
kernel leaves. Higher-level resource modules use this vocabulary rather than
importing the journal, algebra or operation modules directly.

### Specifications and occurrences

A specification contains immutable behaviour. An occurrence contains that
specification and at most one argument:

```lua
local Facility = require('fibers.resource.authoring')

local read_spec = Facility.read(location, Facility.result.value, resource)
local read_op = Facility.op(read_spec)

local write_spec = Facility.replace(location, Facility.result.boolean, resource)
local write_op = Facility.bind(write_spec, value)
```

The same specification may be shared by many occurrences and executions.
Mutable perform state belongs to the activation, journal and search.

### Locations

Create authoritative committed state through `Facility.location`:

```lua
local location = Facility.location(box, {
  algebra = 'replace',
  domain = 'plain',
  value = initial,
})
```

The portable version 1 algebras are:

```text
replace
add
presence
finite_map
machine
```

A location has no mutable mirror, refresh callback or installation callback.
Behaviour following commitment is a typed effect.

### Patches and outcomes

Patch constructors are under `Facility.patch`:

```lua
Facility.patch.replace(value)
Facility.patch.add(delta)
Facility.patch.put(value)
Facility.patch.remove()
Facility.patch.take()
Facility.patch.map_put(key, value, policy)
Facility.patch.map_remove(key)
Facility.patch.machine(successor)
```

A rule returns `nil` when presently blocked, or an outcome when ready:

```lua
return Facility.outcome(patch_or_nil, results...)
```

Every transition outcome must carry a canonical, nil-preserving Fibers value
pack. `Facility.outcome` constructs that pack for ordinary results. If a facility
already has a packed result, use `Facility.outcome_packed`; passing an ordinary
table with an `n` field is not equivalent. Resource authoring is a trusted
boundary: the kernel relies on this invariant and does not inspect or repair
ambiguous result representations during search.

Nils and result arity are preserved. A read-only outcome passes `nil` as its
patch.

### Inspect rules

An inspect rule cannot write:

```lua
local positive = Facility.rule.inspect({
  location = counter._location,
  resource = counter,
  demand = 'up',
  visibility = 'together',
  step = function(value)
    if value <= 0 then return nil end
    return Facility.outcome(nil, value)
  end,
})
```

Exactly one of `step` or `cursor` is required.

### Change rules

A change rule may stage one patch per outcome:

```lua
local take = Facility.rule.change({
  location = counter._location,
  resource = counter,
  demand = 'up',
  visibility = 'together',
  supply = 'down',
  step = function(value, amount)
    if value < amount then return nil end
    return Facility.outcome(Facility.patch.add(-amount), true)
  end,
})
```

Dynamic change rules require an explicit conservative supply declaration.
Inspect rules derive no outgoing supply. Fixed patch constructors derive supply
from their patch and algebra.

### Visibility, demand and supply

These are the irreducible state-rule search contracts:

```text
visibility = 'own' | 'together'
demand     = nil | 'up' | 'down' | 'any'
supply     = 'none' | 'up' | 'down' | 'any'
```

`visibility = 'own'` requires the rule to remain justified without positive
sibling contribution. `visibility = 'together'` permits compatible sibling
contribution under `together`; `each` still hides it.

Demand must cover every direction capable of turning the rule from blocked to
ready. Supply must cover every direction an outcome may contribute. Broad
declarations cost work; narrow declarations are unsound.

### Enumerable rules

A cursor rule enumerates all local alternatives:

```lua
local choose = Facility.rule.change({
  location = machine._location,
  visibility = 'together',
  supply = 'any',
  cursor = function(state, argument)
    local iterator = alternatives(state, argument)
    return {
      next = function()
        local item = iterator:next()
        if item == nil then return nil end
        return Facility.outcome(
          Facility.patch.machine(item.successor),
          item.result
        )
      end,
    }
  end,
})
```

Returning `nil` from the cursor asserts that every intended local alternative
has been enumerated. There is no separate Witness authoring path.

### Derived properties

Trusted authors do not declare:

```text
serial
enumerable
writes
total
eager
```

They are derived:

```text
serial       from the location algebra
enumerable   from cursor rather than step
writes       from change rather than inspect
total        from closed convenience constructors
eager        from internal search policy
```

Known façades may compile a private one-sided readiness probe. It is not part of
the general authoring record and cannot change denotation.

### Machine façade

`fibers.resource.machine` remains the serial protocol façade:

```lua
local Take = Machine.select('buffer.take', function(state, payload)
  if #state.items < payload.n then return Machine.Wait end
  local value = remove_prefix(state, payload.n)
  return Machine.Ready.write(state, value)
end)
```

Machine query, select and update rules compile to inspect or change rules over a
machine location. Public Machines use the same managed-value domain as Cell. Each rule invocation receives an independent working state and an independent captured payload, so a rule may mutate its working table naturally before returning `Machine.Ready.write(state, ...)`. Query mutation is discarded; a losing candidate's working state is discarded; only the captured successor of a committed write becomes authoritative.

Their seriality, write capability and totality are not separately authored. The supplied Machine rule name is retained on the compiled specification and in blocked-frontier diagnostics. Trusted facilities which use Machine as an internal façade may retain a private representation, but must preserve the same observable transactional laws at their public boundary.

### Linear exchange

Exchange is distinct from state transition:

```lua
local get_spec = Facility.rule.exchange({ resource = rendezvous, role = 'get' })
local put_spec = Facility.rule.exchange({ resource = rendezvous, role = 'put' })
```


### External feeds

External hosts update managed locations through an authorised feed registered
by `fibers.embed.external`:

```lua
External.attach(resource, location, deliver, clear)
```

The delivery functions calculate the next committed value. The feed installs
it, increments the location version, invalidates retained proof and wakes the
runtime.

A managed-state wait is an ordinary inspect rule with an optional `wake`
interest. Its observed location version is the negative evidence used by
`or_else`; there is no general absence callback.

Clock deadlines are the deliberate exception. Monotonic time advances without
location publication, so the built-in Clock primitive validates `now < deadline`
directly.

### Effects and wraps

Irreversible work belongs in a typed effect, never in a state-rule callback.
Effect preparation is speculative; discharge runs after state installation. A
wrap performs participant-local work after commitment.

### Required laws

Every primitive facility should test:

```text
losing choices leave committed state unchanged
sequential continuations see tentative changes
each hides positive sibling supply
together permits only intended hand-off
incompatible parallel changes reject the candidate
cursor alternatives backtrack globally
local exhaustion does not become premature Retry
Unknown never opens fallback
stale candidates fail validation
post-commit actions run only for the selected world
```

These names are executable repository requirements in
`tests/support/facility_conformance.lua`. A trusted primitive test calls
`Conformance.check { ... }` and supplies a check for every applicable law; a
non-applicable law requires an explicit reason rather than disappearing from
review. The same kit exposes `Conformance.differential`, which drives generated
finite cases through independent production and reference translators.
`tests/reference/test_facility_authoring_conformance.lua` applies all ten laws
to authoring-level state rules and compares 192 generated additive cases with
`reference/evaluator.lua`.

Do not attach mutable perform state to a shared specification or `Op`. Do not
add facility-specific evaluator exceptions where a state rule, exchange or
ordinary composition can state the law.


## Phase-integrity review

Trusted extensions must also preserve the boundary between speculative description and committed execution.

### Scope

The source tree contains:

- built-in `map` transforms and `guard` builders across the portable and host-backed facilities;
- 58 built-in state-machine transition definitions, including the 25 Flow
  transitions and five generic socket-lifecycle transitions;
- six typed committed-effect kinds: interrupt, spawn, Closure close-reason,
  Flow notification, host-reactor control and Closure recovery claim.

Each site was reviewed according to the phase in which it runs and the identity
of every value it mutates or calls.

### Permitted callback behaviour

The following do not escape a losing speculative activation and are permitted:

- construction of fresh operation values and immutable result records;
- mutation of tables newly allocated by the callback itself;
- mutation of a copied managed-state value which is returned as a transition
  patch;
- creation of fresh dormant facility graphs inside a `guard` activation;
- monotonic allocator bookkeeping used solely to give fresh internal objects
  distinct identities.

The following are not permitted before commit:

- mutation of a Task, Lifetime, Scope, Closure or host handle which existed
  before the callback activation;
- consumption or clearing of a retained body, frame factory or ownership field;
- mutation of the current managed-state value rather than a returned copy;
- host registration, interruption, spawning, notification, closure or I/O;
- using search exhaustion or effect-preparation refusal as an irreversible fact.

### Regression coverage

`tests/lifetimes/test_phase_integrity.lua` checks both production and reference
evaluators for:

- inert construction and defeat of admission;
- later admission of the same Lifetime by another runtime;
- defeat and reuse of one transactional spawn operation;
- exactly-once body transfer after commit;
- removal of stale spawn-owner field clearing;
- inert cancellation construction and defeat;
- committed close-reason bookkeeping;
- exact cancellation reason and token propagation.
