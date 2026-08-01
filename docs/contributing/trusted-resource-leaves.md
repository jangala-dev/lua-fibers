# Trusted executable resource leaves

The public `Op` graph is the executable operation representation. There is no
compiled programme beneath it. Ordinary library authors should compose public
resources and `Op` combinators. This document is for trusted contributors who
need to add a primitive through `fibers.resource.authoring`.

A leaf specification contains immutable behaviour. A bound primitive `Op`
contains that specification and at most one occurrence argument. Mutable state
belongs to the current execution: its activation, journal, trail, frontier and
effects.

The kernel-facing API remains internal before v1.

## Boundary

A facility must not define search, branch exhaustion, `Retry`, `Unknown`, product
visibility, rollback, candidate validation or commit. Those are kernel rules.

Use the least powerful form which expresses the protocol:

```text
ordinary Op composition
read or fixed patch
direct transition
serial Machine transition
witnessed transition
linear exchange
external observation
```

## Specifications and occurrences

`fibers.resource.authoring` exposes one binding model:

```lua
local Facility = require('fibers.resource.authoring')

local read_spec = Facility.read(location, Facility.result.value, resource)
local read_op = Facility.op(read_spec)

local write_spec = Facility.replace(location, Facility.result.boolean, resource)
local write_op = Facility.bind(write_spec, value)
```

`Facility.op(spec)` creates an unbound occurrence. `Facility.bind(spec, value)`
creates an occurrence carrying one argument. The same immutable specification
may be shared by many occurrences and executions.

The public `fibers.op` module contains only the operation algebra. Tuple packing,
leaf construction and executable specifications are internal concerns.

## Locations

Create committed locations through `Facility.location`:

```lua
local location = Facility.location(box, 'value', {
  algebra = 'replace',
  domain = 'plain',
  value = initial,
})
```

Common fields are:

```text
name                diagnostic name
algebra             replace | add | presence | finite_map | machine
domain              diagnostic/domain marker
value               committed value
version             initial version, normally zero
owner, key           optional facility metadata
clone_value(value)   copy one finite-map entry
put_equal            permit equal parallel finite-map puts
remove_idempotent    permit duplicate finite-map removals
```

The location is the authoritative committed state. Public façades should read
`location.value` and `location.version` directly or return immutable snapshots;
they must not maintain mutable mirrors. Behaviour which follows commitment is a
typed Effect, not a location callback.

Location ownership here is transactional grouping, not Lifetime custody.

## Reads and patches

Fixed operations are direct:

```lua
function Box:read_op()
  return Facility.op(Facility.read(self._location, Facility.result.value, self))
end

function Box:clear_op()
  return Facility.op(Facility.write(
    self._location,
    { kind = 'replace', value = nil },
    Facility.result.boolean,
    self
  ))
end
```

For repeated dynamic writes, retain one specification:

```lua
self._write_spec = Facility.replace(
  self._location,
  Facility.result.boolean,
  self
)

function Box:write_op(value)
  return Facility.bind(self._write_spec, value)
end
```

Result forms are:

```text
Facility.result.value
Facility.result.boolean
Facility.result.project(function(value, leaf) ... end)
```

Use `Facility.change` helpers where available.

## Direct transitions

A transition returns `nil` when presently blocked or one outcome when ready:

```lua
local take_spec = Facility.transition({
  location = location,
  resource = resource,
  demand = 'up',
  accepts_supply = true,
  supplies = 'down',
  writes = true,
  step = function(current, amount)
    if current < amount then return nil end
    return Facility.outcome(Facility.change.add(-amount), true)
  end,
})

function Resource:take_op(amount)
  return Facility.bind(take_spec, amount)
end
```

`Facility.outcome(patch, results...)` preserves nils and result arity. A
read-only transition passes `nil` as its patch.

For monotone resources:

```text
demand = 'up'    additions or presence may establish readiness
demand = 'down'  removals or absence may establish readiness
```

Supply declarations use `'none'`, `'up'`, `'down'`, `'any'`, or the equivalent
canonical set. Under `each`, positive sibling supply is hidden. Under `together`,
compatible supply may be used.

## Serial state machines

`fibers.resource.machine` adapts serial protocols to the direct transition
protocol:

```lua
local Machine = require('fibers.resource.machine')

local Take = Machine.select('buffer.take', function(state, payload)
  if #state.items < payload.n then return Machine.Wait end
  local next_state = copy_state(state)
  local value = remove_prefix(next_state, payload.n)
  return Machine.Ready.write(next_state, value)
end)
```

Modes are `update`, `select` and `query`. Return `Machine.Wait`,
`Machine.Ready.same(results...)`, or
`Machine.Ready.write(successor, results...)`.

## Witnessed transitions

Several local successors use `fibers.resource.witness`:

```lua
local Witness = require('fibers.resource.witness')
local Values = require('fibers.internal.values')

local spec = Witness.spec({
  location = location,
  resource = resource,
  accepts_supply = true,
  supplies = 'any',
  cursor = function(state, payload)
    local iterator = make_iterator(state, payload)
    return {
      next = function()
        local witness = iterator:next()
        if witness == nil then return nil end
        return {
          value = successor(state, witness),
          result = Values.pack(witness),
          writes = true,
        }
      end,
    }
  end,
})
```

The cursor must enumerate every intended witness before returning `nil`.
Rollback and global branching remain evaluator responsibilities.

Deterministic minimum or maximum selection over a finite-map location is the
separate `fibers.resource.extreme` helper.

## Linear exchange

A shared exchange specification may be bound repeatedly:

```lua
local get_spec = Facility.exchange({ resource = rendezvous, role = 'get' })
local put_spec = Facility.exchange({ resource = rendezvous, role = 'put' })

local get_op = Facility.op(get_spec)
local put_op = Facility.bind(put_spec, value)
```

The standard public façade is `Rendezvous`.

## Version waits and clocks

`Facility.version_wait(location, resource)` creates a specification which is
bound to the observed version:

```lua
return Facility.bind(changed_spec, version)
```

Higher-level read/wait loops live in the resource module rather than in
the trusted authoring module.

Clock snapshots use a dedicated trusted `clock_now` leaf. There is no generic
context leaf and no primitive callback with ambient Runtime or Scope authority.
Ownership-transferring I/O `_op` constructors require their destination Scope
explicitly; direct methods may use the current Scope as a convenience.

## External observations

External facilities use a host-maintained location and attach an interest and
negative check to a partial transition. Producer authority is exposed through a
runtime-bound `ExternalFeed`. Delivery must update only the bound facility,
increment its version and invalidate stale negative evidence.

## Effects and wraps

Irreversible work belongs in a typed effect, never in a leaf, guard or transition
callback. Effect preparation is pure; discharge runs after state installation.
A wrap performs participant-local work after commitment.

## Required laws

Every primitive facility should test:

```text
losing choices leave committed state unchanged
sequential continuations see tentative changes
each hides positive sibling supply
together permits only intended hand-off
incompatible parallel changes reject the candidate
witness alternatives backtrack globally
local exhaustion does not become premature Retry
Unknown never opens fallback
stale candidates fail validation
post-commit actions run only for the selected world
```

Do not attach mutable perform state to a shared leaf or Op. Do not add
facility-specific exceptions to the evaluator when a direct transition or
ordinary composition can state the rule.
