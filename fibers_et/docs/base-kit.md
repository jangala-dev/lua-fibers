# Base kit

`fibers` is organised around a small public base kit.  These nouns are the low-level public machinery.  Compound facilities such as `Lifetime` and policies are built above them.  The kernel resource protocol, wait interests and typed consequence machinery remain implementation and extension tools rather than a second user model.

```text
Op       possible transaction
Cell     transactional fact
Channel  synchronous rendezvous
Source   external, host or time occurrence made transactional
Region   transactional ownership boundary
Task     owned running computation
Effect   after-commit runtime obligation
```

The rule of thumb is:

```text
Facts go in Cells.
Meetings go through Channels.
External occurrences arrive through Sources.
Regions record ownership. Compound lifetime facilities build on Regions.
Running work is a Task.
Committed obligations are Effects.
Everything composes as an Op.
```

## Op

An `Op` is immutable transaction syntax.  It can be stored, passed around,
chosen between, sequenced, combined and performed by a fibre.

```lua
local op = fibers.choice(
  inbox:get_op(),
  fibers.clock:after_op(1.0):map(function() return nil, 'timeout' end)
)
```

## Cell

A `Cell` is transactional state.  Cell functions are speculative: they may run
more than once during search and must be pure.

```lua
local counter = fibers.Cell.new(0)

local inc = counter:read_op():and_then(function(n)
  return counter:write_op(n + 1):map(function() return n + 1 end)
end)

local function wait_until(cell, pred)
  local function loop()
    return cell:snapshot_op():and_then(function(s)
      if pred(s.value) then return fibers.always(s.value) end
      return cell:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

local ready = wait_until(counter, function(n) return n >= 10 end)
```

Use `Effect`, not a cell update function, for committed external work.

## Channel

A `Channel` is a synchronous rendezvous point.

```lua
ch:put_op('hello')
ch:get_op()
```

A send and receive commit only when the runtime finds a compatible world.

## Source

A `Source` brings an external, host or time occurrence into the transaction
algebra.

```lua
local rt = fibers.Runtime.current()
local signal, feed = rt:signal('signal')
local clock = fibers.Source.clock('clock')
local readiness, readiness_feed = rt:readiness_source(fd, 'read')

signal:wait_op()
clock:after_op(0.25)
readiness:readable_op()
feed:set('changed')
readiness_feed:set_ready(true)
```

Source consumers do not mutate. External facts enter through runtime-bound
producer capabilities, or through `rt:arrive(source, ...)`. Signals are latched
facts observed with `wait_op`; queues are occurrence streams consumed
transactionally with `next_op`.

## Region and Task

A `Region` is the generic ownership boundary. A `Task` is the standard owned running computation admitted to a region and started after the admitting transaction commits. Practical code will usually use the `Lifetime` facility, which is built over Region, Task, Source and Effect.

```lua
local life = fibers.Lifetime.new('main')

local task = fibers.perform(life:spawn_op(function()
  return 7
end))

local value = fibers.perform(task:await_op())
```

`Region` remains the sparse ownership primitive: admit, reassign, seal and release. `Lifetime` is the more ergonomic compound facility. Nursery and supervisor-style APIs are policies over lifetimes, not special cases inside the operation algebra.

## Effect

An `Effect` is a typed transaction consequence: runtime-owned work that is
published iff the selected world commits.

```lua
local op = fibers.after_commit(effect)
```

Effects are not participant continuations.  They are prepared and published by
the runtime after resource commit and before selected participants resume.
