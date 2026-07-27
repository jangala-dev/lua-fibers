# Trusted transactional facility authoring

The compact runtime is closed to new transaction semantics but open to new
transactional programmes. Ordinary library authors should compose public
facilities and `Op` combinators. This document is for trusted contributors who
need to add a new primitive facility through the `fibers.resource.authoring`
façade, which encapsulates the kernel IR and ledger.

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

Keep higher-level facilities such as FIFO, Mailbox, Task, Scope and Stream as ordinary Lua composition where practical.

## Trusted authoring façade

Primitive options are created through `fibers.resource.authoring`, not by
calling an `Op` private constructor directly:

```lua
local Facility = require('fibers.resource.authoring')

return Facility.op(public_facility, facility_kind, programme, payload)
```

`Facility.op` attaches the resource descriptor and creates the primitive
occurrence. `public_facility` and `facility_kind` are used for diagnostics and
identity; `programme` is an inert trusted programme. `payload` is optional and
is used when one cached descriptor has several occurrences. Public constructors
should validate stable arguments and must not mutate committed state.

The underlying `Op._primitive` constructor is an implementation detail of this
façade. Trusted facilities should use `Facility.op`, `Facility.static`,
`Facility.descriptor` and `Facility.occurrence` so that the boundary remains
explicit.

## Versioned locations

Create locations through `Facility.location`:

```lua
local Facility = require('fibers.resource.authoring')

local location = Facility.location(box, 'value', {
  algebra = 'replace',
  domain = 'plain',
  value = initial,
  apply = function(value, loc)
    box.value = value
    box.version = loc.version
  end,
})
```

Supported fields include:

```text
name                diagnostic name; derived from owner and suffix by default
algebra             replace | add | presence | finite_map | machine
domain              diagnostic/domain marker
value               committed value
version             initial version, normally zero
owner, key           optional facility metadata
apply(value, loc)    mirror committed state into the public façade
clone_value(value)   copy one finite-map entry when applying map deltas
put_equal            permit equal parallel finite-map puts
remove_idempotent    permit duplicate finite-map removals; default true
```

Here `owner` is kernel location metadata used to group a facility's
transactional locations. It is unrelated to Lifetime custody and grants no
authority over a Lifetime.

A new location algebra belongs in `algebra.lua` only when it has clear
sequential, independent-parallel and interacting-parallel laws and is shared by
materially different facilities.

## Reads and fixed patches

Use the façade's fixed programme constructors where possible:

```lua
function Box:read_op()
  return Facility.static(self, Box.Kind, 'read', {
    location = self._location,
    result = Facility.result.value,
  })
end

function Box:write_op(value)
  return Facility.static(self, Box.Kind, 'patch', {
    location = self._location,
    patch = { kind = 'replace', value = value },
    result = Facility.result.boolean,
  })
end
```

For reusable descriptors with a per-occurrence payload, construct the descriptor
once with `Facility.descriptor` and create occurrences with
`Facility.occurrence`.

Current result codecs include:

```text
Facility.result.value
Facility.result.boolean
Facility.result.project(function(value, programme) ... end)
```

Current patch shapes are:

```text
{ kind = 'replace', value = value }
{ kind = 'add', delta = number }
{ kind = 'presence', ops = { ... } }
{ kind = 'finite_map', ops = { ... } }
{ kind = 'machine', steps = { ... } }
```

Use `Facility.change` helpers where one exists. Facility code should prefer an
existing façade rather than construct complex patches directly.

## Claims

A claim is a partial query followed by a fixed transition. Standard uses include
Counter take, Keyed presence or absence, Index pop and Lease admission.

```lua
local programme = Facility.claim({
  location = location,
  demand = 'up',
  query = {
    kind = 'predicate',
    predicate = 'ge',
    threshold = amount,
  },
  change = Facility.change.add(-amount),
  result = { kind = 'constant', value = amount },
})
```

For monotone structures:

```text
demand = 'up'    additions or presence supply readiness
demand = 'down'  removals or absence supply readiness
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

Under `all`, the supplying component of an independent sibling delta is hidden.
Under `tensor`, compatible supply may be used.

`Facility.select` and `Facility.admit` are trusted convenience constructors for
ordered finite-map selection and compatibility-checked insertion.

## Serial machine transitions

Use a machine location when a protocol is naturally one serial state value.

The public Machine transition helpers are normally the simplest route:

```lua
local Machine = require('fibers.resource.machine')

local transition = Machine.select('buffer.take', function(state, payload, context)
  if #state.items < payload.n then
    return Machine.Wait
  end

  local next_state = copy_state(state)
  local value = remove_prefix(next_state, payload.n)
  return Machine.Ready.write(next_state, value)
end, 10, function(payload)
  assert(type(payload.n) == 'number' and payload.n > 0)
end)
```

Transition modes are:

```text
update   total or ordinarily writable transition
select   partial transition which writes on success
query    partial read-only transition
```

Return values are:

```text
Machine.Wait
Machine.Ready.same(results...)
Machine.Ready.write(successor_state, results...)
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
local programme = Facility.witness({
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
})
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

Use the trusted `exchange` primitive kind for synchronous one-use interaction:

```lua
Facility.static(resource, Kind, 'exchange', { role = 'put', value = value })
Facility.static(resource, Kind, 'exchange', { role = 'get' })
```

The standard public façade is `Rendezvous`. Pairing, participant recruitment, rollback and exhaustive failure remain controlled by the machine. Do not consume an offer eagerly in facility code.

## Version waits

`Facility.static(resource, Kind, 'version_wait', { location = location, version = version })`
waits until a location version differs. Cached descriptors may bind the version
as an occurrence payload. Prefer an ordinary read, predicate or witnessed
read-only transition; resources do not expose general state-dump operations.

## External observations

External facilities use a host-maintained location and attach an interest and negative check to a partial machine transition:

```lua
local option = Facility.external_wait(facility, Kind, location, transition, {
  interest = function(runtime)
    return Interest.external(facility, 'ready', {
      feed = ExternalFeed.for_resource(runtime, facility),
      external_kind = 'example',
    })
  end,
  absence_check = function(runtime)
    return still_absent(runtime, facility)
  end,
})
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
