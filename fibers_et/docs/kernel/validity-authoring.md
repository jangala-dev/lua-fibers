# Managed validity resource authoring

This document is for authors of new resource kinds.  It explains how to build a
resource whose state participates correctly in bounded search, `or_else`
absence, prepared-world validation and external arrivals.

The rule is strict:

```text
Any state that can affect search results must be represented by a managed
validity capability or derived from one.
```

Raw private state is allowed only for diagnostics, cached formatting, names,
statistics or other non-semantic data.

## Shape of a managed resource

A resource normally contains:

```text
committed public state, if needed for diagnostics or API compatibility
managed validity facts, which are authoritative for search validity
_fibers_kind, the resource kind table
```

For example, a simple box resource should not maintain an unobserved version
counter and a separate frontier.  It should use a managed scalar:

```lua
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local pack = Op._pack

local Box = {}
Box.__index = Box

local BoxKind = { name = 'box' }

function Box.new(value, name)
  local box = setmetatable({ name = name or 'box', _fibers_kind = BoxKind }, Box)
  box.value = Validity.scalar(value, box.name .. ':value')
  return box
end

function Box:read_op()
  return Op._resource(self, BoxKind, { op = 'read' })
end

function Box:write_op(value)
  return Op._resource(self, BoxKind, { op = 'write', value = value })
end
```

## Evaluation

`Kind.eval(resource, payload, ctx)` may inspect managed facts.  Capability reads
record observations automatically.

```lua
function BoxKind.eval(box, payload, ctx)
  if payload.op == 'read' then
    local value = box.value:get(ctx)
    return Result.ready(Proposal.new(pack(value)))
  elseif payload.op == 'write' then
    local c = Proposal.new(pack(true))
    local rec = Resource.ensure(c, box, BoxKind)
    rec.has_write = true
    rec.write = payload.value
    return Result.ready(c)
  end
  error('unknown box command ' .. tostring(payload.op), 2)
end
```

A read that observes committed state should go through the managed capability.
A write should record a proposal.  It must not mutate committed state during
`eval`.

## Journals and projection

If an operation may read after a tentative write in the same transaction, the
resource still needs normal resource records and projection.

```lua
function BoxKind.clone(rec)
  return { kind = BoxKind, has_write = rec.has_write, write = rec.write }
end

function BoxKind.merge_seq(dst, src)
  if src.has_write then dst.has_write = true; dst.write = src.write end
  return true
end

function BoxKind.merge_par(dst, src)
  if src.has_write and dst.has_write and dst.write ~= src.write then
    return false, 'box-conflict'
  end
  if src.has_write then dst.has_write = true; dst.write = src.write end
  return true
end

function BoxKind.project(box, rec, query)
  if query == 'value' then
    if rec and rec.has_write then return rec.write, true end
    return box.value:project(), true
  end
  return nil, false
end
```

Use `Resource.project(ctx, resource, query)` when later operations in the same
transaction must see earlier tentative writes.

## Prepare and apply

`prepare` validates the proposed journal against committed state.  `apply` is
the only phase that mutates committed resource state.

```lua
function BoxKind.prepare(box, rec, resolve)
  if rec.has_write then
    return { kind = BoxKind, resource = box, write = resolve(rec.write) }
  end
  return nil, nil, true
end

function BoxKind.apply(prepared)
  prepared.resource.value:set(prepared.write, 'box write')
end
```

The call to `scalar:set` updates the value and bumps the correct stamp.  The
resource author does not name a frontier.

## Absence

If a resource can certify absence for `or_else`, its absence path should use the
same managed facts as its evaluation path.

For a queue-like resource:

```lua
local item = queue:peek(ctx)
if not item then
  -- The empty fact was observed by peek(ctx).  Any later push to an empty queue
  -- will bump that fact and invalidate the absence proof.
  return Result.none()
end
```

Do not create a separate manual absence frontier.  The fact that made the
resource absent should be observed by the capability method that discovered the
absence.

## External feeds

External arrivals should mutate managed capabilities directly:

```lua
source.events:push(event, 'host event')
source.ready:set('read', true, 'fd readable')
source.signal:set(value, 'signal')
source.driver_epoch:bump('driver state changed')
```

Feed code must not walk solver cursors or observer lists.  It updates managed
state, bumps stamps through the capability, and wakes the runtime through the
normal host/runtime path.

## Choosing capabilities

Use the most precise capability that naturally describes the state:

```text
single value or mode        scalar
boolean readiness           level
latched notification        signal
ordered consuming events    queue
keyed records               map
membership                  set
exclusive ownership         claim
timeout/deadline            clock
computed predicate          derived
opaque custom state         epoch
```

`epoch` is the safe fallback, but it is deliberately coarse.  Prefer structured
facts where they give useful cursor reuse.

## Things not to do

```lua
-- Do not mutate validity-relevant raw tables directly.
resource.items[#resource.items + 1] = item

-- Do not remember to bump a frontier by hand in ordinary resource code.
resource.frontier:invalidate()

-- Do not create fallback named frontiers.  Resources must declare managed facts.
```

The strict branch has removed the fallback named-frontier path.  A resource that
needs validity must own managed facts explicitly.
