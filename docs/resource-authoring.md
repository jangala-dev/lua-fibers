# Trusted transactional facility authoring

The compact runtime is closed to new transaction semantics but open to new transactional programmes. Ordinary library authors should compose public facilities and `Op` combinators. This document is for trusted contributors who need to add a new primitive facility by compiling operations to `fibers.kernel.ir`.

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

## Operation façade

Primitive operations are created with the internal `Op._resource` constructor:

```lua
local Op = require('fibers.atoms.op')
local IR = require('fibers.kernel.ir')

return Op._resource(public_facility, facility_kind, programme)
```

`public_facility` and `facility_kind` are used for diagnostics and identity. `programme` is an inert IR record. Public constructors should validate stable arguments and must not mutate committed state.

## Versioned locations

Create a location with `Store.new_location`:

```lua
local Store = require('fibers.kernel.store')

local location = Store.new_location {
  name = 'box:value',
  merge = 'replace',
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
merge               replace | add | presence | finite_map | machine
domain              diagnostic/domain marker
value               committed value
version             initial version, normally zero
owner, key           optional facility metadata
apply(value, loc)    mirror committed state into the public façade
clone_value(value)   copy one finite-map entry when applying map deltas
put_equal            permit equal parallel finite-map puts
remove_idempotent    permit duplicate finite-map removals; default true
```

A new merge algebra belongs in the store only when it has clear sequential, independent-parallel and interacting-parallel laws and is shared by materially different facilities.

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

Current result kinds include internal forms used by the standard atoms, such as `identity`, `presence_bool`, `presence_value`, `index_entry`, `scalar_snapshot` and `counter_state`. Treat these names as kernel implementation details.

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

Under `all`, the supplying component of an independent sibling delta is hidden. Under `tensor`, compatible supply may be used.

`IR.select` and `IR.admit` are internal convenience constructors for ordered finite-map selection and compatibility-checked insertion.

## Serial machine transitions

Use a machine location when a protocol is naturally one serial state value.

The public Scalar transition façade is normally the simplest route:

```lua
local Scalar = require('fibers.atoms.scalar')

local transition = Scalar.transition {
  name = 'buffer.take',
  mode = 'select',
  supply = 'interacting',
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

`order` defines the stable serial order for accepted steps on one machine location. `supply = 'none'` prevents same-world sibling or participant supply and requires explicit sequencing.

Flow and Region are substantial examples of this form.

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
  supply = 'interacting',
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

The older eager `enumerate` callback is adapted to a cursor for source compatibility. Do not use it for significant search spaces.

Petri and Calendar are the principal examples.

## Linear exchange

Use `IR.exchange` for synchronous one-use interaction:

```lua
IR.exchange(resource_identity, 'put', value)
IR.exchange(resource_identity, 'get')
```

The standard public façade is `Rendezvous`. Pairing, participant recruitment, rollback and exhaustive failure remain machine-owned. Do not consume an offer eagerly in facility code.

## Version waits and snapshots

`IR.version_wait(location, version)` waits until a location version differs. Scalar and Region expose public `changed_op` forms.

`IR.snapshot(resource, kind)` invokes the small fixed snapshot handling in the machine. It is currently used by Keyed and Lease. Prefer an ordinary read or witnessed read-only transition for new facilities unless a shared snapshot form is justified.

## External observations

External facilities use a host-owned location and attach an interest and negative check to a partial machine transition:

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

Clock uses a timer interest and a pull-validated deadline check rather than feed mutation.

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
unique ownership
linear consumption
ordered witness preference
cursor completeness on finite cases
```

## Performance guidance

Prefer:

```text
small immutable programme records
small domain-specific deltas
persistent or copy-on-write state roots
lazy indexed witness cursors
stable location identities
coarse pure calculations outside hot branch loops
```

Do not add facility-owned solver hooks. Optimise recognised IR and delta forms or add a new shared kernel form only after materially different facilities demonstrate the same need.
