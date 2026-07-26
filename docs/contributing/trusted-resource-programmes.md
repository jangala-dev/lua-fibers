# Trusted transactional facility authoring

The compact runtime is closed to new transaction semantics but open to new transactional programmes. Ordinary library authors should compose public facilities and `Op` combinators. This document is for trusted contributors who need to add a new primitive facility by compiling options to `fibers.internal.kernel.ir`.

The kernel-facing API is internal and may change before a stable release.

A facility must not define:

```text
search or branch exhaustion
Retry or Unknown
product visibility
rollback
candidate validation
atomic commit
```

Those are fixed kernel responsibilities.

> This is a contributor interface, not a public extension protocol. The IR, ledger and algebra live under `fibers.internal.kernel`, may change before or after version 1, and must not be used by installed application facilities.

Ordinary facilities should instead follow `../advanced/facility-authoring.md` and depend only on supported public modules.


## Preferred construction order

Use the least powerful form which expresses the protocol:

```text
ordinary Op composition
read or fixed patch
claim
serial machine transition
witnessed transition
linear exchange
external observation
```

Keep higher-level facilities such as Queue, Mailbox, Task, Scope and Stream as ordinary Lua composition where practical.

## Option façade

Primitive options are created with the internal `Op._resource` constructor:

```lua
local Op = require('fibers.op')
local IR = require('fibers.internal.kernel.ir')

return Op._resource(public_facility, facility_kind, programme)
```

`public_facility` and `facility_kind` are used for diagnostics and identity. `programme` is an inert IR record. Public constructors should validate stable arguments and must not mutate committed state.

## Versioned locations

Create a location with `Ledger.new_location`:

```lua
local Ledger = require('fibers.internal.kernel.ledger')

local location = Ledger.new_location {
  name = 'box:value',
  algebra = 'replace',
  domain = 'plain',
  value = initial,
  owner = box,
  apply = function(value, loc)
    box.value = value
    box.version = loc.version
  end,
}
```

Supported fields include:

```text
name                diagnostic name
algebra             replace | add | presence | finite_map | machine
domain              diagnostic/domain marker
value               committed value
version             initial version, normally zero
owner, key           optional facility metadata

Here `owner` is kernel location metadata used to group a facility's transactional
locations. It is unrelated to Lifetime custody and grants no authority over a
Lifetime.
apply(value, loc)    mirror committed state into the public façade
clone_value(value)   copy one finite-map entry when applying map deltas
put_equal            permit equal parallel finite-map puts
remove_idempotent    permit duplicate finite-map removals; default true
```

A new location algebra belongs in `algebra.lua` only when it has clear sequential, independent-parallel and interacting-parallel laws and is shared by materially different facilities.

## Reads and fixed patches

```lua
function Box:read_op()
  return Op._resource(self, Box.Kind,
    IR.read(self._location, 'identity'))
end

function Box:write_op(value)
  return Op._resource(self, Box.Kind,
    IR.patch(
      self._location,
      { kind = 'replace', value = value },
      'constant', true
    ))
end
```

Current result kinds include internal forms used by the built-in resource programmes, such as `identity`, `presence_bool`, `presence_value`, `index_entry`, `scalar_snapshot` and `counter_state`. Treat these names as kernel implementation details.

Current patch shapes are:

```text
{ kind = 'replace', value = value }
{ kind = 'add', delta = number }
{ kind = 'presence', ops = { ... } }
{ kind = 'finite_map', ops = { ... } }
{ kind = 'machine', steps = { ... } }
```

Facility code should prefer an existing façade rather than construct complex patches directly.

## Claims

A claim is a partial query followed by a fixed transition. Standard uses include Counter take, Keyed presence or absence, Index pop and Lease admission.

```lua
local programme = IR.claim {
  location = location,
  orientation = 'up',
  query = {
    kind = 'predicate',
    predicate = 'ge',
    threshold = amount,
  },
  transition = {
    kind = 'static',
    patch = { kind = 'add', delta = -amount },
  },
  result_kind = 'constant',
  result_value = amount,
}
```

For monotone structures:

```text
orientation = 'up'    additions or presence supply readiness
orientation = 'down'  removals or absence supply readiness
```

Dependency footprints use one canonical supply set:

```lua
supplies = { up = true }
supplies = { down = true }
supplies = { up = true, down = true }
supplies = { any = true }
```

The string forms `'none'`, `'up'`, `'down'` and `'any'` are accepted when
constructing trusted transitions and are normalised immediately to that set.
`any` is an explicit declaration for an unordered state algebra; omission is
not treated as `any`.

Under `all`, the supplying component of an independent sibling delta is hidden. Under `tensor`, compatible supply may be used.

`IR.select` and `IR.admit` are internal convenience constructors for ordered finite-map selection and compatibility-checked insertion.

## Serial machine transitions

Use a machine location when a protocol is naturally one serial state value.

The public Scalar transition façade is normally the simplest route:

```lua
local Scalar = require('fibers.resource.scalar')

local transition = Scalar.transition {
  name = 'buffer.take',
  mode = 'select',
  accepts_supply = true,
  supplies = 'any',
  order = 10,
  validate = function(payload)
    assert(type(payload.n) == 'number' and payload.n > 0)
  end,
  step = function(state, payload, context)
    if #state.items < payload.n then
      return Scalar.Wait
    end

    local next_state = copy_state(state)
    local value = remove_prefix(next_state, payload.n)
    return Scalar.Ready.write(next_state, value)
  end,
}
```

Transition modes are:

```text
update   total or ordinarily writable transition
select   partial transition which writes on success
query    partial read-only transition
```

Return values are:

```text
Scalar.Wait
Scalar.Ready.same(results...)
Scalar.Ready.write(successor_state, results...)
```

The callback receives only explicit state, payload and a restricted context. It must be deterministic, non-yielding and free of irreversible effects.

`order` defines the stable serial order for accepted steps on one machine location.

Every transition declares two independent properties:

```text
accepts_supply   whether same-world sibling or recruited state may make this
                 transition ready

supplies         which demand directions this transition may make ready for
                 another participant: none, up, down, any, or an explicit set
```

For example, a read-only query normally declares `supplies = 'none'`; a partial
consumer which may be enabled by a sibling producer declares
`accepts_supply = true`.  A transition which requires explicit sequencing uses
`accepts_supply = false`.  Missing declarations are errors for trusted
programmes; there is no conservative compatibility default.

Flow and the Lifetime store are substantial examples of this form.

## Witnessed transitions

Use a witnessed transition when one state admits several local successors:

```text
S -> Ready(S₁, result₁), Ready(S₂, result₂), ...
```

Provide a lazy cursor factory:

```lua
local programme = IR.witness_transition {
  location = location,
  group = location,
  accepts_supply = true,
  supplies = 'any',
  cursor = function(state, payload, context)
    local iterator = make_iterator(state, payload)
    return {
      next = function()
        local witness = iterator:next()
        if witness == nil then return nil end
        return {
          value = successor(state, witness),
          result = Op._pack(witness),
          writes = true,
        }
      end,
    }
  end,
}
```

Each cursor result may contain:

```text
value     successor state when writes is true
result    packed participant result
writes    whether the location changes
```

The machine treats each witness as an ordinary global branch. If another lane later fails, it rolls back and calls `next()` again.

The cursor factory and cursor must be deterministic and non-yielding. They must enumerate every intended witness before returning nil. Returning nil is a local exhaustion claim; global Retry is still established only by the machine after all enclosing alternatives are exhausted.


Petri and Calendar are the principal examples.

## Linear exchange

Use `IR.exchange` for synchronous one-use interaction:

```lua
IR.exchange(resource_identity, 'put', value)
IR.exchange(resource_identity, 'get')
```

The standard public façade is `Rendezvous`. Pairing, participant recruitment, rollback and exhaustive failure remain controlled by the machine. Do not consume an offer eagerly in facility code.

## Version waits and snapshots

`IR.version_wait(location, version)` waits until a location version differs. Scalar and Scope inspection expose versioned change forms.

`IR.snapshot(resource, kind)` invokes the small fixed snapshot handling in the machine. It is currently used by Keyed and Lease. Prefer an ordinary read or witnessed read-only transition for new facilities unless a shared snapshot form is justified.

## External observations

External facilities use a host-maintained location and attach an interest and negative check to a partial machine transition:

```lua
IR.machine_transition {
  location = location,
  resource = facility,
  transition = transition,
  interest = function(runtime)
    return Interest.external(facility, 'ready', {
      feed = ExternalFeed.for_resource(runtime, facility),
      external_kind = 'example',
    })
  end,
  absence_check = function(runtime)
    return still_absent(runtime, facility)
  end,
}
```

Producer authority is exposed through a runtime-bound `ExternalFeed`. Delivery must update only the bound facility, increment its location version and invalidate any negative proof which could become false.

Clock uses a timer interest and a pull-validated deadline check rather than feed mutation. Relative `after_op` syntax is a guard elaboration into an absolute `at_op`; the core clock primitive therefore handles only explicit observations and deadlines.

## Effects and wraps

Irreversible work belongs in a typed effect, never in search callbacks. Effect preparation must be pure. Discharge runs after location state has committed.

Use a wrap for participant-local post-commit computation. A wrap may perform a new transaction, but it cannot affect the world which has already committed.

## Required laws

Every new primitive facility should test:

```text
losing choices leave committed state unchanged
sequential continuations see their own tentative changes
all hides positive sibling supply
tensor permits only intended hand-off
parallel incompatible deltas reject the candidate
witness alternatives backtrack globally
local exhaustion does not become premature Retry
Unknown never opens fallback
stale positive and fallback candidates fail validation
post-commit actions run only for the selected world
```

Also test structure-specific laws such as:

```text
associativity and commutativity where promised
idempotence
conservation
unique token association
linear consumption
ordered witness preference
cursor completeness on finite cases
```

## Performance guidance

Prefer:

```text
small stable programme records
small domain-specific deltas
persistent or copy-on-write state roots
lazy indexed witness cursors
stable location identities
coarse pure calculations outside hot branch loops
```

Do not add facility-specific solver hooks. Optimise recognised IR and delta forms or add a new shared kernel form only after materially different facilities demonstrate the same need.
