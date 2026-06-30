# Validity algebra

The validity algebra is the resource-side partner to the eventful transaction
algebra.

The transaction algebra says how options compose into possible committed worlds.
The validity algebra says when a saved search, absence proof or prepared world is
still safe to reuse.

The governing rule is:

```text
A saved search may resume, and a prepared world may commit, only while the
managed facts it observed still have the same stamps.
```

This branch uses **pull validation**.  Mutations bump generation-stamped facts;
observers do not get pushed invalidation messages.  A cursor, absence proof or
prepared world validates the facts it recorded when it is resumed or committed.

## Why this exists

`or_else`, bounded search and external arrivals all depend on absence being
well-founded.  A fallback is only lawful while the facts used to certify the
primary's absence remain true.  Similarly, a bounded cursor may continue only if
its previous search prefix still describes the current world.

The old frontier model put much of that responsibility on manual invalidation.
The managed validity model makes resource state observable and mutable only
through capabilities that automatically record observations and bump the right
stamps.

Resource authors should not call `frontier:invalidate` in normal resource code.
They should declare managed facts and interact through their methods.

## The algebraic basis

The minimal basis is:

```text
Scalar        one replaceable fact
Keyspace      keyed membership and keyed values
Sequence      ordered consuming facts: empty, head and tail
Time          deadline frontiers that mature as time advances
Derived       validity-preserving views over other facts
Epoch         conservative opaque fact
```

The public capability kit in `fibers.kernel.validity` provides practical forms
built from this basis:

```text
scalar        Scalar
level         scalar-like boolean facts keyed by readiness mode
signal        latched non-consuming state
queue         Sequence
clock         Time
map           Keyspace
set           membership-only Keyspace
claim         ownership-specialised Keyspace
derived       computed view whose dependencies are whatever it reads
epoch         conservative opaque validity fact
```

`map`, `set`, `claim` and `derived` are production capabilities.  They are not
currently used by many built-in resources, but they are suitable for resource
authors to build on.

## Pull validation

`fibers.kernel.frontier` now provides small generation-stamped fact objects.
An observer records `(frontier, stamp)` pairs.  Validation compares those stamps
with current frontier generations.

```text
search read:
  capability observes frontier F at generation n

commit or feed:
  capability mutates managed state and bumps affected frontiers

resume or prepare:
  observer validates that all recorded frontiers still have their recorded stamps
```

Mutation is therefore local and cheap.  Resource code does not know which solver
cursors or worlds may have observed it.

## Capability reference

### Scalar

A scalar is a single replaceable fact.

```lua
local Validity = require('fibers.kernel.validity')
local v = Validity.scalar(0, 'counter')

local n = v:get(ctx)       -- observes counter:value
v:set(n + 1)               -- bumps counter:value if the value changed
v:bump('external change')  -- conservative explicit bump
```

Use it for scalars, modes, state fields and simple versions.

### Level

A level is a keyed boolean fact.

```lua
local ready = Validity.level('fd-ready')

if ready:get(ctx, 'read') then ... end  -- observes fd-ready:read
ready:set('read', true)
ready:set('write', false)
```

Use it for readiness modes and predicate-like state.

### Signal

A signal is a latched, non-consuming fact.

```lua
local sig = Validity.signal('button')

local value, present = sig:get(ctx) -- observes button:state
sig:set(value)                      -- latches value and bumps state
sig:clear()                         -- clears latch and bumps state
```

Multiple waiters may observe the same signal value.  A signal is not a queue.

### Queue

A queue is an ordered consuming sequence with distinct empty, head and tail
facts.

```lua
local q = Validity.queue('events')

local first = q:peek(ctx) -- observes head when non-empty, empty when empty
q:push(event)             -- bumps tail, and empty/head if it was empty
q:take(1)                 -- bumps head, and empty if it becomes empty
```

Use it for occurrence streams, byte buffers and work queues.

### Clock

A clock gives deadline frontiers.  A wait for a deadline observes the frontier
for “time is still before this deadline”.

```lua
clock:observe_before(ctx, deadline)
clock:invalidate_matured(now)
```

The runtime calls `invalidate_matured` as time advances.

### Map

A map is a managed keyspace.  It distinguishes three kinds of fact:

```text
membership(key)   whether key is present
value(key)        the value at an existing key
structure         the set of present keys / count / iteration shape
```

```lua
local m = Validity.map('sessions')

local exists = m:contains(ctx, id)      -- observes membership(id)
local value, present = m:get(ctx, id)   -- observes membership(id), then value(id)
local n = m:count(ctx)                  -- observes structure

m:set(id, value)                        -- bumps membership/structure if new,
                                        -- bumps value if value changed
m:remove(id)                            -- bumps membership, value and structure
```

Presence is tracked separately from value.  A present key may hold `nil` without
being confused with absence.

### Set

A set is a membership-only keyspace built over `map`.

```lua
local s = Validity.set('subscribers')

if s:contains(ctx, who) then ... end
s:add(who)
s:remove(who)
```

### Lease

A lease is an ownership-specialised keyspace.  It is useful for slots, ownership
pools and exclusive resource rights.

```lua
local c = Validity.lease('buffers')

if c:is_free(ctx, slot) then ... end       -- observes membership(slot)
local owner, present = c:owner(ctx, slot)  -- observes membership and value

c:acquire(slot, owner)     -- succeeds only if free or already same holder
c:release(slot, owner)     -- optionally checks owner
c:transfer(slot, old, new) -- explicit owner change while still leased
```

`is_free` observes membership only.  A transfer from one owner to another while
the slot remains leased does not invalidate a waiter that only cared whether
the slot was free.

### Derived

A derived view has no independent frontier.  Its validity is exactly the facts
read by its body.

```lua
local can_send = Validity.derived(function(ctx)
  return connected:get(ctx) and tx_slots:is_free(ctx, 'main')
end, 'can-send', { cache = true })

if can_send:get(ctx) then ... end
```

With `{ cache = true }`, a derived view reuses the cached result only while the
observer recorded during the previous computation still validates.  It then
replays those observations into the caller's context.

### Epoch

An epoch is the conservative escape hatch.

```lua
local e = Validity.epoch('driver')

e:observe(ctx)
e:bump('driver state changed')
```

Use it when a resource's internal validity cannot yet be decomposed precisely.
It is correct but less precise than structured facts.

## Laws

The capability kit is governed by these laws.

```text
Observation law
  Any successful search result records every managed fact it relied on.

Mutation law
  Any semantic mutation bumps every managed fact whose truth may have changed.

Validation law
  A saved cursor, absence proof or prepared world may be reused only if all
  recorded stamps still match.

Conservatism law
  It is legal to observe or bump a coarser fact than necessary.  It is illegal
  to omit a fact that may affect the result.

Overlay law
  Search reads must see earlier tentative writes in the same transaction.

Commit law
  Real stamps change only at commit or external feed, never during speculative
  search.

Derived law
  A derived view is valid exactly while the facts observed during its derivation
  remain valid.

Epoch law
  An epoch observation is conservative for the whole opaque resource state it
  represents.
```

## Built-in resource status

The built-in resources use managed facts:

```text
Scalar                  scalar
Source.signal         signal
Source.events         events
Source.readiness      level
Source.clock          clock
Rendezvous               epoch
Task                  epoch
Region/Ownership      epoch
Flow/Reservoir        epoch
Interrupt token       epoch
```

Some resources still keep public diagnostic versions or mirrors for user-facing
APIs.  Those mirrors are not the validity mechanism.

## Tests

The relevant tests are:

```text
tests/test_validity_algebra.lua
  capability-level observation, mutation and validation tests

tests/test_validity_cursor_adversarial.lua
  bounded cursor tests for map, claim and derived dependencies

tests/test_frontier_invalidation.lua
  pull-validation behaviour for observers and worlds
```
