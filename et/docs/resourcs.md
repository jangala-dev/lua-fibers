# Resource implementation process

The resource protocol is open-world.  The evaluator, solver and runtime do not
know whether a resource is a cell, ledger, event, queue, semaphore or user type.
A resource participates by returning `Op._resource(resource, kind, payload)` and
by providing a kind table with the relevant capabilities.

## Execution pipeline

A resource operation follows this path:

```text
public method
  -> Op._resource(resource, Kind, payload)
  -> Kind.eval(resource, payload, ctx)
  -> candidates / waits / rendezvous endpoints / resource records
  -> generic solver search
  -> Kind.prepare(resource, record, resolve)
  -> prepared resource commits
  -> Kind.apply(prepared, log)
```

The runtime applies prepared commits mechanically.  It should not inspect the
concrete resource's record shape.

## Minimal public wrapper

A resource value usually stores committed state plus `_et_kind`:

```lua
local Box = {}
Box.__index = Box

local BoxKind = { name = 'box' }

function Box.new(value)
  return setmetatable({
    value = value,
    version = 0,
    _et_kind = BoxKind,
  }, Box)
end

function Box:get_op(Op)
  return Op._resource(self, BoxKind, { op = 'get' })
end

function Box:set_op(Op, value)
  return Op._resource(self, BoxKind, { op = 'set', value = value })
end
```

A public method should be small: construct a payload and delegate the semantics
to the kind table.

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

`Kind.eval(resource, payload, ctx)` evaluates the resource operation in the
current instant.  It returns an `et.algebra.result` value.

Useful helpers:

```lua
local Candidate = require('et.algebra.candidate')
local Result = require('et.algebra.result')
local Resource = require('et.resources.protocol')
local pack = require('et.op')._pack
```

Return current candidates with:

```lua
return Result.cands({ candidate })
```

Return absence with:

```lua
return Result.none()
```

Return a future wake interest with:

```lua
return Result.wait({ kind = 'wakeup', source = resource, interest = 'ready' })
```

A read-only operation normally creates a candidate whose values are the current
projected view:

```lua
function BoxKind.eval(box, payload, ctx)
  if payload.op == 'get' then
    local c = Candidate.new(pack(Resource.project(ctx, box, 'value')))
    local rec = Resource.ensure(c, box, BoxKind)
    rec.read = rec.read or box.version
    return Result.cands({ c })
  end
end
```

The important point is that reads should use `Resource.project(ctx, resource,
query)`, not the committed field directly, when they need to see tentative writes
from earlier operations in the same transaction.

## Resource records

A candidate carries sparse resource records:

```text
candidate.res[resource] = record
record.kind = Kind
```

Use `Resource.ensure(c, resource, Kind)` to create or fetch the record for a
candidate.

A record is a proposal, not a mutation.  It should contain enough information to:

- validate freshness later;
- merge sequentially and in parallel;
- project tentative state to subsequent operations;
- prepare a concrete commit.

For a simple cell-like resource:

```lua
local function read_record(c, box)
  local rec = Resource.ensure(c, box, BoxKind)
  rec.read = rec.read or box.version
  return rec
end

local function write_record(c, box, value)
  local rec = read_record(c, box)
  rec.has_write = true
  rec.write = value
  return rec
end
```

## Cloning

`Kind.clone(record)` copies the record for candidate cloning.

```lua
function BoxKind.clone(rec)
  return {
    kind = BoxKind,
    read = rec.read,
    has_write = rec.has_write,
    write = rec.write,
  }
end
```

Keep records compact.  Do not store large derived structures unless the kind owns
an explicit sharing strategy.

## Sequential merge

`Kind.merge_seq(dst, src)` merges `src` after `dst` within one sequential
transaction.  Later sequential operations may refine or overwrite earlier local
proposals.

```lua
function BoxKind.merge_seq(dst, src)
  dst.read = dst.read or src.read
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
  dst.read = dst.read or src.read
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
  return box.value, true
end
```

The protocol calls `project` first with the current overlay record, then with
`nil` to ask for committed state.  Return `value, true` when the query is known;
return `nil, false` when the kind does not recognise the query.

## Preparation

`Kind.prepare(resource, record, resolve)` is the certification gate.  It checks
freshness against committed state and returns an inert prepared commit.

```lua
function BoxKind.prepare(box, rec, resolve)
  if rec.read ~= box.version then return nil, 'stale' end

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
  p.resource.value = p.write
  p.resource.version = p.resource.version + 1
end
```

`log` has:

```lua
{
  transaction = {},
  obligation = {},
}
```

Append public consequences or obligations there if the resource needs them.  The
runtime publishes the log after prepared resources are applied.

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
local ph = Candidate.new_ph()
local c = Candidate.new(pack(ph))
c.endpoints[#c.endpoints + 1] = {
  kind = 'rendezvous',
  role = 'get',
  key = channel,
  ph = ph,
  origin = ctx.origin,
}
return Result.cands({ c })
```

Put endpoint:

```lua
local c = Candidate.new(pack(true))
c.endpoints[#c.endpoints + 1] = {
  kind = 'rendezvous',
  role = 'put',
  key = channel,
  value = payload.value,
  origin = ctx.origin,
}
return Result.cands({ c })
```

`tensor` may close compatible endpoints internally when topology permits it.
`all` does not close internal endpoints between lanes.

The endpoint protocol is intentionally smaller than the local resource protocol:
custom get/put rendezvous is supported by shape, but new rendezvous matching
relations may require extending `et.solver.rendezvous`.

## Waitable resources

A waitable resource returns `Result.wait(...)` when it is not ready, and a normal
candidate when it is ready.

```lua
function EventKind.eval(event, payload, _ctx)
  if event.ready then
    return Result.cands({ Candidate.new(event.vals or pack(true)) })
  end
  return Result.wait({ kind = 'wakeup', source = event, interest = 'ready' })
end
```

A wait is not a candidate.  It is reported by the runtime only when no current
transaction commits and no residual fallback replaces the waiting branch.

## Checklist for a new resource kind

1. Define a resource object and store `_et_kind = Kind`.
2. Expose public methods that return `Op._resource(self, Kind, payload)`.
3. Implement `Kind.eval`.
4. If the resource has transactional state, implement records with
   `Resource.ensure`.
5. Implement `clone`, `merge_seq`, `merge_par` and `project` for those records.
6. Implement `prepare` to check freshness and build inert prepared commits.
7. Implement `apply` to perform the mutation and append any log entries.
8. Add a focused test proving that the resource participates without edits to
   evaluator, solver or runtime.

The open-world invariant is:

```text
eval, merge, projection, preparation and application are owned by the kind table;
the runtime only applies certified prepared commits.
```
