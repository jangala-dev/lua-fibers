# Implementation guide

This document maps the algebra in `docs/algebra.md` onto the current
implementation.  It is intended for contributors changing the runtime, resource
protocol, host adapters or facilities.

The practical pipeline is:

```text
user code performs an Op
Runtime records a waiting fibre
transaction_net searches for a compatible world
resource journals and effects prepare
Runtime commits the world
selected fibres resume
host waits only when no current world can commit
```

## Module map

```text
fibers.lua
  Public convenience facade.

fibers/atoms/op.lua
  Public option constructors and derived forms.

fibers/atoms/{scalar,rendezvous,source,region,effect,...}.lua
  Public atom kit resources and values.

fibers/{task,sleep,scope,queue,pool,flow,stream,policy,...}.lua
  Compound user-facing facilities: task, scope, policy, sleep, flow, stream.

fibers/kernel/runtime.lua
  Cooperative runtime, fibre lifecycle, driver boundary and commit execution.

fibers/kernel/transaction_net.lua
  Search engine for possible worlds.

fibers/kernel/resources.lua
  Resource candidate protocol, journals, prepare/apply support and observer validation.

fibers/kernel/validity.lua
  Managed validity capabilities: scalar, queue, signal, level, clock, map, set,
  claim, derived and epoch.

fibers/kernel/frontier.lua
  Generation-stamped validity facts and pull-validated observers.

fibers/kernel/effect/*
  Typed effect objects, sets, preparation and discharge.

fibers/internal/source_state.lua
  Source-specific committed state built on managed validity capabilities.

fibers/host/*
fibers/runner.lua
  Host adapters and standalone driver loops.
```

## Option representation

`fibers.atoms.op` defines immutable-ish syntax nodes.  They are plain Lua tables
with a metatable and a `kind` field.

The internal option kinds are intentionally small:

```text
always
choice
bind
or_else
product
wrap
guard
with_nack
nack
emit
prim
```

Several public forms are derived:

```text
map      -> bind + always
never    -> empty choice
all      -> product with allow_internal = false
tensor   -> product with allow_internal = true
empty product -> always(empty_rows())
named_*  -> ordinary products/choices plus derived mapping
```

Keep this separation.  Public convenience is good; kernel primitive count should
stay small.

### Important constructor rules

`map` is derived from `and_then` and must preserve multiple returns:

```lua
function Op:map(fn)
  return self:and_then(function(...)
    return Op.always(fn(...))
  end)
end
```

`wrap` is a post-commit boundary.  `map` and `and_then` are rejected after a wrap
has appeared below the option.  Adjacent wraps may be fused because they do not
affect search.

`all` and `tensor` must remain semantically distinct even though both are
represented as `product`.  The distinction is `allow_internal`.

## Runtime lifecycle

`fibers.kernel.runtime` owns fibres and host interaction.

A live fibre is owned by exactly one of:

```text
ready queue
waiting frontier
current running slot
```

Completed fibres are retired immediately.  They are not retained for later
joining by the runtime.  Structured ownership is expressed through `Task`,
`Region` and `Scope`, not by keeping completed coroutine stacks in the
scheduler.

### Running user code

A fibre calls:

```lua
rt:perform(op)
```

`perform` checks that it is running inside a fibre, then yields a request to the
runtime.  The runtime records the fibre as waiting on an option and searches
for a committed world among waiting fibres.

When a world commits, the selected fibre is resumed with raw committed values and
a post-commit value transformer.  The transformer applies wrap chains inside the
resumed fibre before `perform` returns to user code.

### Driver boundary

Host arrivals and source clearing are driver options.  They must come from
external driver code, not from inside a running fibre.  The runtime enforces this
with phase checks.

Typical standalone control flow:

```text
Runtime:run()
  drain ready fibres
  search waiting frontier
  if a world commits, resume selected fibres
  if no world commits, report wait interests to host
  host blocks or polls
  host delivers source arrivals
  repeat
```

## Transaction net search

`fibers.kernel.transaction_net` is the search engine.  It builds candidate worlds
without mutating committed state.

The main internal pieces are:

```text
Outcome
  hit(world), miss(cert, waits), unknown(waits, reason)

Attempt
  mutable speculative search state with a rollback trail

Task
  an option plus continuation stack, resource environment and root id

World
  selected root results, environments, effect set and nack obligations

Solver
  root scanning, search bounds, cursor/cache support and commit candidate search
```

### Continuation frames

The current continuation frames are deliberately few:

```text
bind
wrap
product_lane
```

`map` no longer has a frame.  `all` and `tensor` share the product-lane frame.

### Local reduction

The solver reduces local proof structure before handing a task back to full
search.  Local reduction handles deterministic constructors such as `always`,
`bind`, `wrap` and `guard` while stopping at rendezvous, product, resource, choice
or absence-sensitive structure.

This keeps simple options cheap without adding separate semantics for derived
forms.

### Branch search

The solver explores branches such as:

```text
task branch
rendezvous branch
product lane completion
or_else primary/fallback branch
```

When a branch fails because it is impossible under current observations, the
result is `miss`.  When it fails because proof is stale, bounded, or resource
freshness cannot be established, the result is `unknown`.

### Validity and cursor reuse

Resource state that can influence search is represented by managed validity
capabilities in `fibers.kernel.validity`.  Search reads record generation stamps
through the active observer.  Commit and external feed writes bump stamps through
the same capability objects.

A bounded cursor is therefore reusable only while the facts it observed still
validate.  Mutation does not walk solver cursors.  The solver pulls validation
when a prepared world is committed, a cached world is reused, or a bounded cursor
resumes.

This replaces the older push-style frontier invalidation model.  `frontier.lua`
remains as the small generation-stamp substrate.

`unknown` must not be treated as absence.

### or_else handling

`or_else` is implemented as a residual search point, not as a local branch in
ordinary choice.

The primary branch is searched first with access to the global transaction
space.  Only if the primary produces a certified `miss` may the fallback open.
The fallback is searched with the primary's absence certificate.  A fallback world
must still compete normally with other roots; fallback is not allowed to mask an
available non-fallback world elsewhere.

This is the implementation point that protects fallback safety.

### Product handling

`product` represents both public `all` and public `tensor`.

```text
allow_internal = false  all
allow_internal = true   tensor
```

A product creates a group and one lane task per lane.  Lane completion records
packed lane results and merges lane resource environments into the group.  When
all lanes complete, the product returns a rows table to the outer task.

For `allow_internal = false`, rendezvous between lanes in the same group is
forbidden.  For `allow_internal = true`, lane-to-lane rendezvous is permitted.

## Resources

Resources are implemented through `fibers.kernel.resources` and kind tables.
A public resource method usually returns:

```lua
Op._resource(resource, Kind, payload)
```

The transaction net calls the resource kind during search.  The resource kind
returns candidates, waits, absence or unknown according to the kernel resource
protocol.

A selected resource journal follows this path:

```text
search candidate
  -> resource record in candidate environment
  -> merge with other records
  -> prepare against committed state
  -> apply after world selection
```

### Contributor rules for resources

Resource kind methods are trusted transactional machinery.  They must:

```text
not yield
not call perform/spawn/run
not mutate committed state during search
not use raw Lua errors for ordinary application rejection
report stale state conservatively
report absence conservatively
```

User-level validation should be expressed with option composition before the
trusted resource option is constructed.

## Effects

Effects are typed post-commit obligations.

A selected world contains an effect set.  Effect kinds provide:

```text
key
merge
prepare
discharge
order/failure policy
```

Commit order is:

```text
prepare resource journals and effects
apply prepared resource journals
discharge prepared effects
settle nacks
resume selected fibres
apply wraps inside perform
```

Effect discharge failure is currently fatal runtime failure.  This is deliberate:
by discharge time, the world has committed and there is no speculative rollback
path.

## Sources and hosts

The runtime does not block directly.  It reports wait interests.  Host adapters
turn those interests into process-level waiting, polling or callbacks.

Sources are the transactional representation of external facts.  A host adapter
must deliver external readiness or timer events by calling runtime arrival
methods.  Arrivals mutate managed validity facts and bump their stamps; saved
search frontiers are rejected later by pull validation if they observed those
facts.

Host adapters must preserve these properties:

```text
no lost readiness arrivals
closed handles deregister cleanly
readiness source state matches the advertised level/edge semantics
clock waits wake at or after their deadline
external callbacks enter through the driver boundary
```

The pure/manual host is useful for algebra tests.  The fd/epoll/nixio/luaposix
hosts validate the runtime against process-level I/O and should be tested in a
real host matrix.

## Facilities

Facilities are compounds over the atom kit and kernel.  They should avoid adding
new kernel primitives.

### Scope and policy

`Scope` builds structured concurrency out of:

```text
Region ownership
Task admitted computation
Source observation
Effectful spawn/wake/interrupt obligations
settlement resources
policy choices
```

`fibers.launch(policy, fn)` is the friendly structured entry point.  Raw runtime
spawning is for hosts, embedders and low-level tests.

### Flow and stream

Streams are built from flows.  A flow is a transactional byte reservoir with
leases, backpressure, EOF/failure state and endpoint settlement.  A stream is a
compound of two flows plus owned reader/writer views.

Important stream invariants:

```text
losing read branches free no bytes
losing write branches append no bytes
peek observes without freeing
read is peek plus committed prefix free
splice moves bytes as one committed world
backpressure is retained-byte capacity
EOF and failure are committed flow state
```

Host-backed streams pump between host handles and flows using source arrivals and
transactional flow options.

## Error and phase policy

The runtime distinguishes ordinary option absence from runtime failure.

```text
absence
  ordinary transaction outcome; may lead to waits or fallback

unknown
  solver/resource cannot certify absence; must not open fallback as if absent

runtime error
  user or trusted machinery violated the runtime contract

fatal runtime error
  committed or trusted machinery failed where rollback is not possible
```

Protected calls exist because Lua runtimes differ in whether `pcall`/`xpcall`
can yield.  Kernel code should use `fibers.kernel.protected` when it must be
portable across PUC Lua, LuaJIT and texlua.

## Adding new behaviour

Prefer this order:

```text
1. Can it be expressed as an Op composition?
2. Can it be a resource kind?
3. Can it be a typed effect kind?
4. Can it be a source plus host adapter?
5. Can it be a facility over Region/Task/Scope/Flow?
6. Only then consider a new kernel primitive.
```

New kernel primitives are expensive.  They must interact correctly with choice,
product, fallback, absence, resource journals, effects, wraps, nacks and bounded
search.

## Tests to add with changes

Changes to the core algebra should normally add or preserve tests for:

```text
choice identity and flattening
tensor vs all internal rendezvous distinction
or_else fallback safety
absence and managed validity invalidation
local proof reduction
resource stale prepare refusal
lost branch rollback
no speculative effects
wrap boundary behaviour
nack selection/loss behaviour
protected-call fallback path
host readiness delivery
settlement and ownership invariants
```

For derived constructor changes, structural tests may need to change, but
behavioural tests should continue to hold.


## Shared premise-resource helpers

Premise-aware resources use a small internal helper layer rather than each atom
re-implementing the same bookkeeping.  `fibers.kernel.premise_helpers` owns
common premise utilities such as deterministic id ordering, pairwise
compatibility checks, record-view extraction, and small map-copy helpers.

`fibers.kernel.resources.presence_journal` owns the shared selected-remove
journal used by presence-like resources.  `Index` uses it for
`inserts/removes/selected_removes`; `Keyed` uses it for
`puts/removes/selected_removes/replacements`.  This keeps the handoff law in one
place:

```text
parallel supply + selected remove = handoff/cancellation
sequential selected remove then supply = replacement
```


## Premise helper layer

Common premise-resource mechanics live in `fibers/kernel/premise_helpers.lua`.
The helper layer owns deterministic premise sorting, pairwise compatibility,
record extraction from resource views, map cloning, and the shared
`project_selective` law used by state-dependent selections.  In particular,
`project_selective` captures the common rule used by Index, Keyed and Scalar
selection-style operations: sibling positive supply may satisfy demand under
`tensor`, while under `all` it may only constrain an already possible selection.

Presence-style selected removals live in
`fibers/kernel/resources/presence_journal.lua`, shared by `Index` and `Keyed`.
This keeps the handoff/replacement law in one place rather than reimplementing
selected-remove merging in every atom.
