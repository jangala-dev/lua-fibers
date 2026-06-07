# Base kit

`fibers` is organised around a small public base kit.  These nouns are the low-level public machinery.  The kernel resource protocol,
wait interests and typed consequence machinery remain implementation and
extension tools rather than a second user model.

```text
Op       possible transaction
Cell     transactional fact
Channel  synchronous rendezvous
Source   external, host or time occurrence made transactional
Region   lifetime and ownership boundary
Task     owned running computation
Effect   after-commit runtime obligation
```

The rule of thumb is:

```text
Facts go in Cells.
Meetings go through Channels.
External occurrences arrive through Sources.
Lifetimes live in Regions.
Running work is a Task.
Committed obligations are Effects.
Everything composes as an Op.
```

## Op

An `Op` is immutable transaction syntax.  It can be stored, passed around,
chosen between, sequenced, combined and performed by a fibre.

```lua
local op = fibers.choice(
  inbox:recv_op(),
  fibers.clock:after_op(1.0):map(function() return nil, 'timeout' end)
)
```

## Cell

A `Cell` is transactional state.  Cell functions are speculative: they may run
more than once during search and must be pure.

```lua
local counter = fibers.Cell.new(0)

local inc = counter:update_op(function(n) return n + 1 end)
local ready = counter:wait_op(function(n) return n >= 10 end)
```

Use `Effect`, not a cell update function, for committed external work.

## Channel

A `Channel` is a synchronous rendezvous point.

```lua
ch:send_op('hello')
ch:recv_op()
```

A send and receive commit only when the runtime finds a compatible world.

## Source

A `Source` brings an external, host or time occurrence into the transaction
algebra.

```lua
local signal = fibers.Source.manual('signal')
local clock = fibers.Source.clock('clock')
local readiness = fibers.Source.poll(fd, 'read')

signal:next_op()
clock:after_op(0.25)
readiness:readable_op()
```

A source is the dual of an effect: sources bring outside facts in; effects send
committed obligations out.

## Region and Task

A `Region` is a lifetime and ownership boundary.  A `Task` is an owned running
computation admitted to a region and started after the admitting transaction
commits.

```lua
local region = fibers.Region.new('main')

local task = fibers.perform(region:spawn_op(function()
  return 7
end))

local status, value = fibers.perform(task:join_op())
```

`Region` is mechanism.  Nurseries, supervisors and compatibility scopes should
be policy built over regions.

## Effect

An `Effect` is a typed transaction consequence: runtime-owned work that is
published iff the selected world commits.

```lua
local op = fibers.after_commit(effect)
```

Effects are not participant continuations.  They are prepared and published by
the runtime after resource commit and before selected participants resume.
