# Observation journal

The observation journal is the read side of bounded transaction search.

A resource journal records what a selected candidate world would write at commit.
A consequence log records what the runtime must publish after commit.  The
observation journal records mutable facts the search relied on while producing
candidates, waits, or absence proofs.

```text
resource journal
  candidate writes

observation journal
  search observations

consequence log
  after-commit obligations
```

A bounded cursor may resume only while its observation journal is current.
This matters most for residual fallback: `p or_else q` may open `q` only under
observations that prove `p` has no committing world now.  If those observations
become stale, the proof of absence is stale too.

## Observations

The kernel currently uses two compact observation forms.

```text
object observation
  object is still at the observed stamp

time horizon observation
  host time has not reached the observed deadline
```

Versioned objects use their `version` field by default.  A future host-facing
object may provide a custom `fresh(stamp, rt)` method if a simple version field
is not enough.

Time observations are horizons rather than ticks.  A cursor that observed
`now < deadline` remains current while that remains true.  Time passing does not
matter until the earliest observed deadline matures.

## Attempt context

Resource evaluation should not inspect mutable runtime, resource, or host state
without recording the observation.  Use the attempt context:

```lua
local version = ctx:observe_version(resource)
local now = ctx:now()
ctx:before(deadline)
```

For custom observable objects, `ctx:observe(obj, ...)` calls
`obj:snapshot(rt, ...)`, records the returned stamp, and later validates it with
`obj:fresh(stamp, rt)`.

The resource protocol rule is:

```text
no unrecorded dynamic observations during resource evaluation
```

Pure operation syntax, immutable local values, and tentative candidate overlays
need no observation.  Mutable committed state, source readiness, queue contents,
interrupt tokens, readiness facts, and clock-before-deadline facts do.

## Observation journal versus commit validation

The observation journal does not replace resource preparation.

```text
observation journal
  can this paused search continue?

resource prepare
  can this selected world still commit?
```

Both are needed.  A selected world may still need normal resource validation even
when the paused search observations remain current.
