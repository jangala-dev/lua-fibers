# Sleep facility

The sleep facility is a small library layer over clock `Source` options.  It
provides exactly two option constructors:

```lua
fibers.sleep_until_op(t)
fibers.sleep_op(d)
```

`sleep_until_op(t)` is an absolute clock wait.  It can commit when the runtime's
host clock has reached `t`.

`sleep_op(d)` is relative sleep.  It is implemented as a guard which fixes the
absolute deadline once for the perform attempt:

```lua
return Op.guard(function(ctx)
  return sleep_until_op(ctx:now() + d)
end)
```

This matters because option search may be rebuilt.  A relative sleep must not
slide forward every time the solver restarts; `sleep_op(4)` means four seconds
from the beginning of this perform attempt, not four seconds from each later
search pass.

## Standalone flow

A standalone runner can use pending time waits to decide when to re-enter the runtime:

```text
perform(sleep_op(4))
  deadline = rt:now() + 4
  clock wait reports Time(deadline)
  runner asks its host to block until deadline or another event
  runner re-enters Runtime:run
  clock wait commits once rt:now() >= deadline
```

A timer heap can be useful in the standalone host adapter, but it is not part of
the sleep semantics.  It only helps the host decide when to call `step`.

## Embedded flow

In an embedded host, the host owns the loop:

```text
perform(sleep_op(4))
  runtime reports a Time(deadline) wait
  host records the deadline in its own loop
  host calls rt:step() when appropriate
  sleep commits if the host clock has reached the deadline
```

If the host never calls `step` again, a sleeping fibre does not resume.  That is
intentional: the runtime is embeddable and does not own the process event loop.

## Beginner standalone example

See `examples/08_sleep.lua` for a deliberately small standalone driver using
Lua's `os.time`.  The example shows the important control flow:

```text
fibre performs sleep_op(4)
runtime reports a Time(deadline) wait
driver waits until os.time() reaches the deadline
driver calls the runtime again
fibre resumes
```

The example uses the pure Lua host.  That host is deliberately limited: it uses
`os.time` by default for the clock and `os.execute("sleep N")` for time waits.
It does not support polling or arbitrary host events.  The optional Linux hosts
`fibers.host.luajit_linux` and `fibers.host.nixio` provide more precise
blocking and readiness support without changing `sleep_op` itself.

## Observation validation

Clock waits participate in world validation.  A transaction world that has
observed `now < deadline` remains valid while that fact is true.  It becomes
stale only when `now >= deadline`, at which point the sleep option may become
a candidate.
