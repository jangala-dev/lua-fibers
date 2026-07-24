# Direct methods and options

Fibers supports two views of the same ordinary action.

```lua
local update = status_updates:get()
```

performs the action immediately in the current fibre. The corresponding `_op`
method constructs an inert **option**:

```lua
local receive_update = status_updates:get_op()
```

The option may be combined before it is submitted to `perform`:

```lua
local outcome = perform(choice(
  reply_ready:get_op(),
  stop_requested:get_op(),
  sleep_op(30):map(function()
    return 'response deadline reached'
  end)
))
```

## The rule

For the common sequential surface:

```text
verb_op(...)   construct an inert option
verb(...)      perform verb_op(...) now
```

The direct method is a thin call to the shared `perform` implementation. It is
not a second implementation and does not have different cancellation, failure
or lifetime semantics.

Examples include:

```lua
channel:get_op()       channel:get()
channel:put_op(value)  channel:put(value)
stream:read_line_op()  stream:read_line()
stream:write_op(data)           stream:write(data)
udp:send_to_op(data, address)  udp:send_to(data, address)
udp:receive_from_op(opts)      udp:receive_from(opts)
task:await_op()                 task:await()
```

## When to use each form

Use direct methods for straightforward sequential fibre code:

```lua
local command = commands:get()
apply_command(command)
acknowledgements:put('completed ' .. command)
```

Use `_op` methods whenever an action must be composed:

```lua
local selected, detail = perform(named_choice({
  completed = reply_ready:get_op(),
  stopped = stop_requested:get_op(),
  timed_out = deadline:get_op(),
}))
```

Options are also required for transactional sequencing, products and certified
fallback:

```lua
local intention = perform(
  attack_op(agent, target)
    :or_else(take_cover_op(agent))
    :or_else(return_to_patrol_op(agent))
)
```

## Visibility of suspension

`perform(option)` always marks an explicit option-resolution boundary. Direct
methods are intentionally less visually explicit and are best used where the
sequential reading is the important one.

Projects which require every suspension boundary to remain visible can use only
`_op` methods and `perform`. The two styles may be mixed without changing the
underlying semantics.

## What does not receive a direct twin

A direct method is provided only when it is an unsurprising, common sequential
action. Low-level resource transitions, inspection options, facility-authoring
interfaces and lifecycle protocol steps generally remain option-only.

The suffix remains meaningful throughout the library: `_op` always means that
the returned value is an option and that no action has yet been performed.
