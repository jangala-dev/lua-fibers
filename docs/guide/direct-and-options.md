# Direct methods and options

Fibers supports two views of the same ordinary action.

```lua
local message = inbox:get()
```

performs the action immediately in the current fibre. The corresponding `_op`
method constructs an inert **option**:

```lua
local receive = inbox:get_op()
```

The option may be combined before it is submitted to `perform`:

```lua
local message = perform(choice(
  inbox:get_op(),
  sleep_op(1):map(function()
    return 'timeout'
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
local request = connection:read_line()
connection:write('reply: ' .. request .. '\n')
connection:flush()
```

Use `_op` methods whenever an action must be composed:

```lua
local request = perform(choice(
  connection:read_line_op(),
  stop:next_op():map(function()
    return nil, 'stopped'
  end)
))
```

Options are also required for transactional sequencing, products and certified
fallback:

```lua
local result = perform(
  primary:get_op()
    :or_else(backup:get_op())
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
