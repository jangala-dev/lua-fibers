# Trusted resource authoring

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

## Boundary

A facility must not implement search, branch exhaustion, `Retry`, `Unknown`,
product visibility, rollback, candidate validation or commit. Those are kernel
rules.

Only `fibers.resource.authoring` constructs managed locations and executable
kernel leaves. Higher-level resource modules use this vocabulary rather than
importing the journal, algebra or operation modules directly.

## Specifications and occurrences

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

## Locations

Create authoritative committed state through `Facility.location`:

```lua
local location = Facility.location(box, 'value', {
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

## Patches and outcomes

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

Nils and result arity are preserved. A read-only outcome passes `nil` as its
patch.

## Inspect rules

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

## Change rules

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

## Visibility, demand and supply

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

## Enumerable rules

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

## Derived properties

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

## Machine façade

`fibers.resource.machine` remains the serial protocol façade:

```lua
local Take = Machine.select('buffer.take', function(state, payload)
  if #state.items < payload.n then return Machine.Wait end
  local successor = copy_state(state)
  local value = remove_prefix(successor, payload.n)
  return Machine.Ready.write(successor, value)
end)
```

Machine query, select and update rules compile to inspect or change rules over a
machine location. Their seriality, write capability and totality are not
separately authored. The supplied Machine rule name is retained on the compiled
specification and in blocked-frontier diagnostics.

## Linear exchange

Exchange is distinct from state transition:

```lua
local get_spec = Facility.rule.exchange({ resource = rendezvous, role = 'get' })
local put_spec = Facility.rule.exchange({ resource = rendezvous, role = 'put' })
```


## External feeds

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

## Effects and wraps

Irreversible work belongs in a typed effect, never in a state-rule callback.
Effect preparation is speculative; discharge runs after state installation. A
wrap performs participant-local work after commitment.

## Required laws

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

Do not attach mutable perform state to a shared specification or `Op`. Do not
add facility-specific evaluator exceptions where a state rule, exchange or
ordinary composition can state the law.
