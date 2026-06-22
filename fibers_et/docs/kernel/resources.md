# Resource implementation process

The resource protocol is open-world.  The transaction net and runtime do not
know whether a resource is a cell, event, queue, flow reservoir or user type.
A resource participates by returning `Op._resource(resource, kind, payload)` and
by providing a kind table with the relevant capabilities.

## Execution pipeline

A resource option follows this path:

```text
public method
  -> Op._resource(resource, Kind, payload)
  -> Kind.eval(resource, payload, ctx)
  -> resource candidates or waits
  -> semantic transaction-net search
  -> optional absence certification for or_else
  -> Kind.prepare(resource, record, resolve)
  -> prepared resource commits
  -> Kind.apply(prepared, log)
```

The runtime applies prepared commits mechanically.  It should not inspect the
concrete resource's record shape.

## Trusted transactional machinery contract

Resource kind code is trusted transactional machinery.  It runs inside the
transactional interpretation, search, preparation or commit path, not as an
ordinary recoverable algebra callback.

This contract applies to kind-table methods such as:

```text
eval
project
merge_seq
merge_par
absence
prepare
apply
summary
clone
```

It also applies to functions that a resource kind deliberately evaluates as part
of its own protocol.  For example, a cell update function executed by
`CellKind.eval` is participating in transactional resource interpretation.  It
must compute the proposed transition and return normally.  It should not use an
ordinary Lua error to express application-level rejection.

Trusted transactional machinery must:

- be total for valid committed state, payloads and records;
- avoid yielding;
- avoid calling `perform`, `spawn`, `step` or `run`;
- avoid mutating committed resource state before `apply`;
- use `prepare` for validation against committed state;
- use `apply` for the actual committed mutation.

If trusted transactional machinery raises a raw error and that error escapes
through a public `run` or `step` call, the public driver boundary restores driver
state, marks the runtime failed with a fatal `runtime_error`, and re-raises the
fatal error.  The runtime object is then unusable.  This is intentional: the
runtime cannot know which speculative structures, resource records or commit
steps were left partially evaluated.

Application-level validation should usually be expressed in recoverable algebra
callbacks, for example with `guard`, `map` or `and_then`, before constructing the
trusted resource option.

## Managed validity facts

Every resource that can affect search results must declare managed validity
facts.  The fallback named-frontier path has been removed.  A resource may use
raw private state for diagnostics, names or caches, but committed semantic state
that can influence `eval`, `absence`, `prepare` or external wake decisions must
be represented by `fibers.kernel.validity` capabilities.

The common choices are:

```text
scalar    one replaceable value
level     keyed boolean readiness or mode predicates
signal    latched non-consuming notification
queue     ordered consuming occurrences
clock     deadline frontiers
map       keyed membership and value facts
set       membership-only keyspace
claim     ownership-specialised keyspace
derived   computed view over other managed facts
epoch     conservative opaque validity fact
```

Capability reads record observations automatically.  Capability writes bump the
facts whose truth may have changed.  Resource authors should not name or bump
frontiers directly in normal resource code.

See `docs/validity-algebra.md` for the capability reference and
`docs/kernel/validity-authoring.md` for a worked managed-resource example.

## Minimal public wrapper

A resource value usually stores managed semantic state plus `_fibers_kind`:

```lua
local Op = require('fibers.base.op')
local Validity = require('fibers.kernel.validity')

local Box = {}
Box.__index = Box

local BoxKind = { name = 'box' }

function Box.new(value, name)
  local box = setmetatable({ name = name or 'box', _fibers_kind = BoxKind }, Box)
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

The public methods are small: they construct payloads and delegate semantics to
the kind table.  The managed scalar is the authoritative validity fact for the
box value.

## Kind table capabilities

A kind table may provide:

```lua
local Kind = {
  name = 'example',

  eval = function(resource, payload, ctx) ... end,
  summary = function(payload, out) ... end,

  clone = function(record) ... end,
  merge_seq = function(dst, src) ... end,
  merge_par = function(dst, src) ... end,
  project = function(resource, record, query) ... end,

  prepare = function(resource, record, resolve) ... end,
  apply = function(prepared, log) ... end,
}
```

`eval` is required for any `Op._resource` node.  The others are required only if
the resource creates local resource records.  Rendezvous-only or wait-only
resources may not need `clone`, `merge_*`, `project`, `prepare` or `apply`.

## Evaluation

`Kind.eval(resource, payload, ctx)` evaluates the resource option in the
current instant.  It returns a `fibers.kernel.resources.result` value.

Useful helpers:

```lua
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Resource = require('fibers.kernel.resources.protocol')
local pack = require('fibers.base.op')._pack
```

Return current candidates with:

```lua
return Result.ready(candidate)
```

Return absence with:

```lua
return Result.none()
```

Return a future wake interest with:

```lua
return Result.wait({ kind = 'wakeup', source = resource, interest = 'ready' })
```

A read-only option normally observes managed state and creates a candidate whose
values are the current projected view:

```lua
function BoxKind.eval(box, payload, ctx)
  if payload.op == 'get' then
    local value = box.value:get(ctx) -- observes box:value
    return Result.ready(Proposal.new(pack(value)))
  elseif payload.op == 'set' then
    local c = Proposal.new(pack(true))
    local rec = Resource.ensure(c, box, BoxKind)
    rec.has_write = true
    rec.write = payload.value
    return Result.ready(c)
  end
end
```

Reads of committed state should go through managed capabilities so bounded
search can record the facts a world relied on.  If a later option in the same
transaction must see an earlier tentative write, use `Resource.project(ctx,
resource, query)` and implement `Kind.project`.

## Resource records

A candidate carries sparse resource records:

```text
candidate.res[resource] = record
record.kind = Kind
```

Use `Resource.ensure(c, resource, Kind)` to create or fetch the record for a
candidate.

A record is a proposal, not a mutation.  It should contain enough information to:

- validate the selected journal later;
- merge sequentially and in parallel;
- project tentative state to subsequent options;
- prepare a concrete commit.

For a simple cell-like resource, the record only needs the proposed write:

```lua
local function write_record(c, box, value)
  local rec = Resource.ensure(c, box, BoxKind)
  rec.has_write = true
  rec.write = value
  return rec
end
```

A resource that validates read versions may also record the managed stamp it
observed, but simple resources can often rely on prepared-world observer
validation instead of carrying an additional version field.

## Cloning

`Kind.clone(record)` copies the record for candidate cloning.

```lua
function BoxKind.clone(rec)
  return { kind = BoxKind, has_write = rec.has_write, write = rec.write }
end
```

Keep records compact.  Do not store large derived structures unless the kind owns
an explicit sharing strategy.

## Sequential merge

`Kind.merge_seq(dst, src)` merges `src` after `dst` within one sequential
transaction.  Later sequential options may refine or overwrite earlier local
proposals.

```lua
function BoxKind.merge_seq(dst, src)
  if src.has_write then
    dst.has_write = true
    dst.write = src.write
  end
  return true
end
```

Return `false, reason` if the sequential composition is semantically invalid.

## Parallel merge

`Kind.merge_par(dst, src)` merges proposals from parallel branches.  It should
reject incompatible concurrent proposals.

```lua
function BoxKind.merge_par(dst, src)
  if src.has_write then
    if dst.has_write and dst.write ~= src.write then
      return false, 'box-conflict'
    end
    dst.has_write = true
    dst.write = src.write
  end
  return true
end
```

Parallel compatibility is part of the transaction search.  Reject conflicts here;
do not defer obvious structural conflicts to `prepare`.

## Projection

`Kind.project(resource, record, query)` answers tentative reads.

```lua
function BoxKind.project(box, rec, query)
  if query ~= 'value' then return nil, false end
  if rec and rec.has_write then return rec.write, true end
  return box.value:project(), true
end
```

The protocol calls `project` first with the current overlay record, then with
`nil` to ask for committed state.  Return `value, true` when the query is known;
return `nil, false` when the kind does not recognise the query.

## Preparation

`Kind.prepare(resource, record, resolve)` is the certification gate.  It validates
the selected journal against committed state and returns an inert prepared commit.

```lua
function BoxKind.prepare(box, rec, resolve)
  if rec.has_write then
    return {
      kind = BoxKind,
      resource = box,
      write = resolve(rec.write),
    }
  end

  return nil, nil, true -- no-op
end
```

Return forms:

- `prepared` — a resource-specific prepared commit;
- `nil, reason` — reject the world, usually because of staleness;
- `nil, nil, true` — valid no-op.

Use the supplied `resolve` function for values that may contain rendezvous
placeholders.  Do not mutate resource state in `prepare`.

## Application

`Kind.apply(prepared, log)` applies a prepared commit.  This is the only place a
normal resource kind should mutate its committed state.

```lua
function BoxKind.apply(p, _log)
  p.resource.value:set(p.write, 'box write')
end
```

Prepared resource application should mutate only committed resource state.
Resources should not append arbitrary effect records to the runtime log.
If a final resource state entails runtime work, return typed effects from
`prepare` as `effect_set` or `effects`; the commit plan will merge,
prepare and discharge them after resource application.

```lua
return {
  kind = BoxKind,
  resource = box,
  write = value,
  effect_set = derived_obligations,
}
```

Prepared effects are discharged by the runtime and then dropped.  Tests or
hosts that need to observe effects should do so through the relevant effect
discharger, not through a runtime-owned journal.

## Static summary

`Kind.summary(payload, out)` is optional but useful for fast paths and pruning.
Set conservative flags.  It is better to over-approximate than to hide an effect.

Examples:

```lua
function BoxKind.summary(payload, out)
  out.resources = true
  out.closed = false
  if payload.op == 'get' then out.reads = true end
  if payload.op == 'set' then out.writes = true end
end
```

A rendezvous resource should set:

```lua
out.endpoints = true
out.closed = false
```

A waitable resource should set:

```lua
out.dynamic = true
out.closed = false
```

## Rendezvous resources

A resource may emit rendezvous endpoints from `eval`.  The current rendezvous
protocol matches endpoints with the same `key` and opposite `role`.

Get endpoint:

```lua
local ph = Proposal.new_ph()
local c = Proposal.new(pack(ph))
c.endpoints[#c.endpoints + 1] = {
  kind = 'rendezvous',
  role = 'get',
  key = channel,
  ph = ph,
  origin = ctx.origin,
}
return Result.ready(c })
```

Put endpoint:

```lua
local c = Proposal.new(pack(true))
c.endpoints[#c.endpoints + 1] = {
  kind = 'rendezvous',
  role = 'put',
  key = channel,
  value = payload.value,
  origin = ctx.origin,
}
return Result.ready(c })
```

`tensor` may close compatible endpoints internally when topology permits it.
`all` does not close internal endpoints between lanes.

The endpoint protocol is intentionally smaller than the local resource protocol.
Channel rendezvous is value-blind: endpoints match by primitive, key and opposite role, and value interpretation belongs in the Op algebra.  Protocols such as Lifetime handoff use ordinary channel rendezvous and inspect offered values in and_then, before commit.

## Waitable resources

A waitable resource returns `Result.wait(...)` when it is not ready, and a normal
candidate when it is ready.

```lua
function EventKind.eval(event, payload, _ctx)
  if event.ready then
    return Result.ready(Proposal.new(event.vals or pack(true)) })
  end
  return Result.wait({ kind = 'wakeup', source = event, interest = 'ready' })
end
```

A wait is not a candidate.  It is reported by the runtime only when no current
transaction commits and no residual fallback replaces the waiting branch.

## Checklist for a new resource kind

1. Define a resource object and store `_fibers_kind = Kind`.
2. Expose public methods that return `Op._resource(self, Kind, payload)`.
3. Implement `Kind.eval`.
4. If the resource has transactional state, implement records with
   `Resource.ensure`.
5. Implement `clone`, `merge_seq`, `merge_par` and `project` for those records.
6. Implement `prepare` to validate the selected journal and build inert prepared commits.
7. Implement `apply` to perform the mutation and append any log entries.
8. Add a focused test proving that the resource participates without edits to
   evaluator, solver or runtime.

The open-world invariant is:

```text
eval, merge, projection, preparation and application are owned by the kind table;
the runtime only applies certified prepared commits.
```
