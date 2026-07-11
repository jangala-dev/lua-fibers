# Resource authoring

This document is the normative guide for adding a transactional resource. Application code should normally compose the standard resources described in `guide.md` rather than extend the kernel protocol.

A resource is trusted transactional machinery. Its implementation participates in speculative search, premise resolution, preparation and commit. An error escaping from this layer is a runtime integrity failure, not an ordinary rejected operation.

## Execution model

A primitive resource operation follows this path:

```text
public method
  -> Op._resource(resource, Kind, request)
  -> Kind.eval(resource, request, ctx)
  -> Ready(proposal), Premise(request), or Retry(proof)
  -> transaction-net search and resource composition
  -> exhaustive premise resolution where required
  -> Kind.prepare(resource, record, resolve)
  -> commit resource journals
  -> Kind.apply(prepared, log)
  -> discharge derived effects
```

Bounded search may return `Unknown`, but `Unknown` is a solver result rather than a resource result.

There is no separate absence callback. The evaluation or exhaustive resolution which concludes that no current solution exists must return the corresponding `RetryProof`.

## Trusted-code rules

Resource methods and callbacks deliberately invoked by them must:

- be deterministic for the state and request supplied;
- be non-yielding;
- avoid `perform`, spawning, stepping and running the runtime;
- avoid irreversible I/O;
- avoid changing committed semantic state before `apply`;
- use managed validity capabilities for every mutable fact affecting search;
- return `Retry` only with sufficient evidence;
- make `apply` total for a successfully prepared record.

Application rejection should normally be represented by operation structure, premises or a permanent retry result, not an arbitrary Lua error.

## Minimal resource shape

A resource value stores managed state and identifies its kind:

```lua
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')

local Box = {}
Box.__index = Box

local BoxKind = { name = 'box' }

function Box.new(value, name)
  local box = setmetatable({
    name = name or 'box',
    _fibers_kind = BoxKind,
  }, Box)

  box.value = Validity.scalar(value, box.name .. ':value')
  return box
end

function Box:get_op()
  return Op._resource(self, BoxKind, { op = 'get' })
end

function Box:set_op(value)
  return Op._resource(self, BoxKind, { op = 'set', value = value })
end
```

Public methods should normally do little more than validate construction-time arguments and build a primitive request.

## Kind capabilities

A full resource kind may define:

```lua
local Kind = {
  name = 'example',

  eval = function(resource, request, ctx) ... end,
  summary = function(request, out) ... end,

  clone = function(record) ... end,
  merge_seq = function(dst, src) ... end,
  merge_par = function(dst, src) ... end,
  project = function(resource, record, query) ... end,

  resolve_premises = function(resource, premises, ctx) ... end,

  prepare = function(resource, record, resolve) ... end,
  apply = function(prepared, log) ... end,
}
```

`eval` is required. Other methods are needed only when the resource creates journals, tentative projections or premises.

The relevant kernel modules are:

```lua
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Resolution = require('fibers.kernel.resources.resolution')
local Resource = require('fibers.kernel.resources.protocol')
local RetryProof = require('fibers.kernel.retry')
local Interest = require('fibers.kernel.interest')
local Validity = require('fibers.kernel.validity')
```

## Evaluation results

`Kind.eval(resource, request, ctx)` returns one of:

```text
Ready(proposal)
Premise(request)
Retry(proof)
```

### Ready

Return a current candidate:

```lua
return Result.ready(proposal)
```

For a read-only operation:

```lua
function BoxKind.eval(box, request, ctx)
  if request.op == 'get' then
    local value = box.value:get(ctx)
    return Result.ready(Proposal.new(Op._pack(value)))
  end
end
```

Capability reads record the validity frontiers used by the candidate.

### Retry

Return `Retry` only when no result can become available without a recorded fact changing:

```lua
function BoxKind.eval(box, request, ctx)
  if request.op == 'expect' then
    local value = box.value:get(ctx)
    if value ~= request.value then
      return Result.retry(ctx:proof('box expectation not met'))
    end
    return Result.ready(Proposal.new(Op._pack(value)))
  end
end
```

Use `Result.permanent(reason)` only for structural impossibility which cannot become ready through resource change.

A mutable-resource retry proof must observe at least one managed frontier unless explicitly permanent. An unjustified `Retry` can make `or_else` commit an invalid fallback.

### Premise

A premise asks the resource resolver to choose a concrete solution after the combined transaction context is known:

```lua
return Result.premise({
  kind = 'take',
  amount = request.amount,
})
```

A premise is not a partial success and not a retry. It may be satisfied by shared stock, by another interacting product lane, or not at all.

## Proposals and resource records

A proposal contains result values, resource journals, effects and other candidate-world contributions. Resource records are sparse:

```text
proposal.res[resource] = record
record.kind = Kind
```

Use `Resource.ensure(proposal, resource, Kind)` to create or retrieve the record.

For the Box example:

```lua
function BoxKind.eval(box, request, ctx)
  if request.op == 'set' then
    local proposal = Proposal.new(Op._pack(true))
    local record = assert(Resource.ensure(proposal, box, BoxKind))
    record.has_write = true
    record.write = request.value
    return Result.ready(proposal)
  end
end
```

A record is a proposed journal, not a mutation. Keep it compact.

## Sequential and parallel composition

`merge_seq(dst, src)` combines `src` after `dst` in one transaction. Later sequential operations may refine or replace earlier tentative state.

```lua
function BoxKind.merge_seq(dst, src)
  if src.has_write then
    dst.has_write = true
    dst.write = src.write
  end
  return true
end
```

`merge_par(dst, src)` combines sibling lanes. It must reject incompatible proposals:

```lua
function BoxKind.merge_par(dst, src)
  if src.has_write then
    if dst.has_write and dst.write ~= src.write then
      return false, 'box-write-conflict'
    end
    dst.has_write = true
    dst.write = src.write
  end
  return true
end
```

Reject structural conflict during merge rather than deferring an obvious incompatibility to preparation.

Required laws are:

```text
Sequential soundness
  the merged record represents the stated ordering

Parallel soundness
  an accepted merge represents both intentions atomically

Conflict refusal
  incompatible intentions reject the candidate world
```

## Tentative projection

A later operation in `and_then` may need to observe an earlier tentative journal. Use `Resource.project(ctx, resource, query)` and define `Kind.project`:

```lua
function BoxKind.project(box, record, query)
  if query ~= 'value' then return nil, false end
  if record and record.has_write then return record.write, true end
  return box.value:project(), true
end
```

The protocol first asks the current overlay record, then the committed resource.

Do not expose provisional values to ordinary Lua code before the transaction structure says they are available. Premise resources are particularly sensitive to this rule.

## Premise resolution

`Kind.resolve_premises(resource, premises, ctx)` returns an exhaustive `Resolution`:

```lua
return Resolution.exhaustive(solutions, proof_or_factory)
```

A solution states which premise identifiers it closes and the result values or shared proposal it supplies:

```lua
{
  ids = { premise_id_1, premise_id_2 },
  results = {
    [premise_id_1] = ctx.pack(...),
    [premise_id_2] = ctx.pack(...),
  },
  proposal = shared_proposal,
}
```

The accompanying proof states that the returned list is complete under the observed facts. It is needed even when solutions exist, because all of them may fail elsewhere in the transaction.

Proof construction may be deferred:

```lua
return Resolution.exhaustive(solutions, function()
  return ctx:proof('all current allocations enumerated')
end)
```

Resolver ordering is semantic. List preferred solutions first. Premise buckets and identifiers are otherwise supplied in stable order.

### Independent and interacting products

Resolver contexts describe the provenance of visible records:

```text
own       the premise lane's own record
outer     enclosing sequential context
sibling   another product lane
```

They also identify the product mode.

The governing law is:

```text
independent product
  sibling records may constrain allocation, but cannot positively supply a fact
  which makes an otherwise impossible premise ready

interacting product
  sibling records may positively supply a fact and complete a handoff
```

This law applies to rendezvous, counters, indices, keyed facts, leases and compound facilities built from them.

## Managed validity

Every mutable semantic fact which may affect evaluation, resolution, preparation or wake decisions must use a managed validity capability from `fibers.kernel.validity`.

Available capabilities include:

```text
scalar    one replaceable value
level     keyed boolean levels
signal    latched non-consuming fact
queue     ordered consuming sequence
epoch     conservative opaque generation
map       keyed membership and values
set       membership view
lease     compatibility state
derived   computed view over facts read by its body
clock     deadline frontiers
```

Reads through these capabilities record observations in the active evaluation context. Writes invalidate the appropriate generation-stamped frontiers.

Choose the narrowest capability which represents the resource's truth. Use `epoch` only where a more precise fact is not practical; it invalidates every dependent proof on any change.

Do not:

- keep search-relevant state only in an ordinary Lua field;
- manually invent named frontiers alongside a managed capability;
- record a broad epoch when a keyed or level fact is available;
- mutate a capability during speculative evaluation;
- cache a derived answer without preserving the observations used to derive it.

## Retry proofs and interests

A `RetryProof` contains:

```text
frontiers      evidence justifying current retry
interests      host-actionable ways an external fact may change
observations   optional diagnostic descriptions
permanent      explicit structural impossibility
```

Frontiers are evidence. Interests are instructions to the host. An internal counter may retry with a frontier and no host interest. Readiness normally retries with both a level frontier and a readiness interest.

`Unknown` must never be converted into `Retry`, including when a work budget is exhausted.

When `or_else` commits a fallback, the primary retry proof remains attached to the candidate and is validated before commit.

## External feeds

An externally fed resource is still an ordinary resource. It additionally exposes a runtime-bound producer capability.

The consumer operation observes managed state and, if necessary, adds a host interest carrying the authorised feed. The host later delivers a state change through that feed.

Required laws are:

```text
Authority
  a feed may update only its bound resource through its bound runtime

Invalidation
  every delivery which may make a retrying operation ready invalidates the
  relevant frontier before search resumes

Serialisation
  external delivery enters through the runtime driver boundary
```

Host I/O itself must not run during transaction search.

## Preparation and application

`Kind.prepare(resource, record, resolve)` runs after a world has been selected but before any journal is applied.

Preparation should:

- validate the journal against current committed state;
- resolve stored substitutions;
- construct a compact prepared record;
- derive typed effects entailed by the final resource state;
- reject stale or invalid candidates without external side effects.

`Kind.apply(prepared, log)` installs committed state. After successful preparation, application should not fail under ordinary conditions.

A simple implementation is:

```lua
function BoxKind.prepare(box, record)
  if not record.has_write then return nil, nil, true end
  return {
    kind = BoxKind,
    box = box,
    value = record.write,
  }
end

function BoxKind.apply(prepared)
  prepared.box.value:set(prepared.value, 'box commit')
end
```

Losing candidates never reach `apply`.

## Effects

A resource may derive typed commit consequences during preparation. Effects belong to the selected world, not to a participant continuation.

Effect kinds define stable keys, merge or conflict behaviour, preparation, ordering and discharge. Preparation is side-effect-free. Discharge occurs after journals commit and before participants resume.

The current guarantee is once per successful in-process commit, not durable exactly-once delivery.

Defeat effects are attached to operation occurrences through `on_defeat`; they are not resource rollback. Speculative journals require no defeat cleanup because they were never applied.

## Resource laws checklist

Before adding a resource, provide tests for:

```text
Value opacity
  returned values do not accidentally expose mutable journal internals

No speculative mutation
  losing alternatives leave committed resource state unchanged

Sequential merge
  ordered operations observe the intended tentative state

Parallel merge
  compatible siblings compose and conflicting siblings are rejected

Projection
  later operations see exactly the tentative facts they are entitled to see

Retry conservatism
  Retry is returned only with sufficient invalidation evidence

Resolution exhaustiveness
  premise solutions and the associated proof cover every current possibility

Preparation
  stale observations reject before any application

Application
  prepared journals install the intended state and invalidate managed facts

Effects
  losing worlds discharge nothing; selected derived effects have stable keys

External delivery
  authorised delivery invalidates every proof it may make obsolete

Product provenance
  independent siblings constrain but do not supply; interacting siblings may
  perform handoff
```

Use focused property-style tests where a resource has a non-trivial allocator or merge algebra. The standard resources and premise tests are the best implementation examples.
