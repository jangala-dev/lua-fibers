# Happy Eyeballs v2 connection strategy

`socket.connect` on a name endpoint combines incremental A and AAAA resolution with staggered
IPv6 and IPv4 connection attempts. Resolution, candidate arrival, attempt
completion and delay expiry remain independent events. The first successful
Stream moves into the caller's Scope; the private race Scope closes every
resolver query, losing Dial and losing Stream before the call returns.

```lua
local socket = require('fibers.socket')

local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  resolution_delay = 0.050,
  attempt_delay = 0.250,
  order_destinations = application_destination_order,
})
assert(connection, report)
```

The implementation follows the Happy Eyeballs v2 coordination model:

- A and AAAA resolution begins concurrently;
- an available IPv6 candidate may start immediately;
- an IPv4-first result briefly waits for IPv6;
- later addresses join the unattempted candidate set;
- connection attempts are staggered rather than started as one burst;
- an immediate failure permits the next attempt without waiting for the full
  stagger delay;
- the first selected successful connection cancels and closes the remaining
  race;
- terminal failure requires both address sources to be closed, no candidate to
  remain, no attempt to be active and no successful connection to await
  collection.

## The race as an option algebra

One Cell machine contains the closed-family flags, globally ordered
unattempted candidates, admitted numeric Dials, stagger deadline and winner.
Each coordinator iteration describes one serial scheduling step:

```lua
local outcomes = attempt_result_ops(current)
local sources = family_completion_ops(current, query)
local progress = choice(admit_next_attempt_op(), wake_ops(current))

return outcomes:or_else(sources:or_else(progress))
```

The ordering is semantic rather than source-order bias. A launch through
`progress` commits only with negative guards proving that no attempt outcome or
DNS completion was ready in the same world. Consequently, a connection which
succeeds at the exact stagger deadline suppresses a second launch.

Candidate admission composes the Cell selection, `socket.dial_op` admission
and the active-attempt state update in one option. The transaction allocates no
file descriptor speculatively: the numeric Dial starts its non-blocking socket
work only after admission commits. Each numeric attempt exposes its definitive
connect result as a one-shot reactor-owned external offer. Attempt completion
then combines the Dial's custody transfer with the winner or failure state
transition. Because completion is an observed external fact rather than a
future task supplier, a result already visible at the stagger or attempt deadline
correctly defeats the fallback timer.

The public facility is the ordinary `Dial`; Happy Eyeballs is the strategy selected
for a name endpoint. Its implementation lives under `fibers.socket.dial.named`,
with the transactional coordinator in `fibers.socket.dial.named.state`. These are
socket-subsystem implementation modules rather than runtime internals.

## One Dial type under custody

`socket.dial_op` admits the ordinary `Dial` Lifetime and selects the named strategy from the endpoint kind:

```lua
local dial = fibers.perform(socket.dial_op(socket.name_endpoint('example.org', 443)))
local connection, report = dial:connect()
assert(connection, report)
```

`dial:connect()` is the direct launch-and-collection convenience. It returns
only after the winner has moved into the target scope and the private race has
closed. The lower-level lifecycle remains selectable:

```lua
local connection, err = fibers.perform(dial:result_op(target_scope))
local report = fibers.perform(dial:report_op())
local closed, close_err = fibers.perform(dial:closed_op())
```

`connected_op` is success-only. `failed_op` observes terminal failure.
`result_op` combines them through certified fallback. A successful connection
which has not yet been collected remains in the Dial's private Scope custody.
Closing the Dial cancels resolution and every outstanding numeric Dial.

There is deliberately no `connect_op`. Starting the private driver is a
committed effect; its later connection result cannot be required by the same
transaction which admits that driver. The public split is therefore the same as
other effectful facilities: an option admits the handle under custody, then its result
operations participate in subsequent choices.

## Resolver integration

The named strategy consumes `Query:family_finished_op` independently for `inet6`
and `inet4`. It does not wait for the resolver's combined terminal list.
Candidates therefore remain dynamic, including addresses which arrive after one
or more connection attempts have started.

An explicit resolver can be supplied:

```lua
local resolver = socket.dns_resolver({
  nameservers = {
    socket.ipv4_address('192.0.2.53', 53),
  },
})

local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  resolver = resolver,
})
```

The DNS selection options accepted by `socket.resolve_name` are also accepted by
`socket.connect` for a name endpoint: `dns`, `nameservers`, `nameserver`,
`resolver_options` and `require_nonblocking`.

## Candidate policy

Every new family completion is merged with the current unattempted set. A
single global destination-ordering policy then ranks all currently available
IPv4 and IPv6 destinations before family interleaving. The first address in
that global order determines the initially preferred family; it is not fixed to
IPv6.

Routing and source-address-sensitive RFC 6724 policy is injected rather than
guessed by the coordinator:

```lua
local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  order_destinations = function(addresses, endpoint, opts)
    return application_destination_order(addresses, endpoint, opts)
  end,
})
```

A host may instead provide `sort_destination_addresses`. One of these global
policies is required by default: the coordinator does not invent a portable
RFC 6724 ranking from address family alone. A host which cannot supply routing
and source-address-aware ordering may opt in explicitly to stable resolver
order:

```lua
local connection, report = socket.connect(socket.name_endpoint('example.org', 443), {
  destination_ordering = 'stable',
})
```

This is reported as `destination_ordering = 'stable'` and is an intentional
non-RFC fallback, not an implicit claim of RFC 6724 compliance.

Ordering callbacks participate in guarded option construction. They therefore
must be immediate, deterministic, non-yielding and side-effect free. Fibers
passes an isolated copy in stable arrival/current-policy order and validates
that the returned list contains only known destinations; omitted destinations
are appended rather than discarded. Stable input order remains available as the
final RFC 6724 tie-break.

After global ordering, `first_family_count` controls how many addresses from the
initially preferred family may be launched before ordinary alternation. The
default is one. Later DNS results re-order only the unattempted set; Dials which
have already begun continue unchanged.

## Timing and connection options

The principal options are:

```lua
{
  resolution_delay = 0.050,
  attempt_delay = 0.250, -- minimum 0.010
  first_family_count = 1,
  timeout = 10.0,
  -- timeout = false, -- disable the deadline
  -- deadline = absolute_monotonic_time,
  maximum_candidates = 64,
  -- By default maximum_active_attempts equals maximum_candidates.
  -- maximum_active_attempts = 4, -- explicit bounded-host profile
  -- attempt_timeout = 2.0,       -- releases a bounded slot after this interval

  nodelay = true,
  local_address_inet6 = socket.ipv6_address('::', 0),
  local_address_inet4 = socket.ipv4_address('0.0.0.0', 0),

  resolver = resolver,
  resolver_options = {},
}
```

A relative `timeout` begins when the admitted Dial driver starts and defaults to
30 seconds when omitted. Set `timeout = false` to disable it. An absolute `deadline` uses the Runtime's monotonic clock. RFC
8305's 10 millisecond minimum connection-attempt delay is enforced.

`maximum_candidates` bounds retained DNS destinations and defaults to 64; the
report records any dropped candidates. In the general profile,
`maximum_active_attempts` defaults to that same bound, so a black-holed earlier
connection does not prevent later candidates from being launched at their
stagger times merely because four attempts are already pending. A constrained
host may set a smaller explicit bound.

A smaller active-attempt bound is an explicit resource/liveness trade-off. Use
`attempt_timeout` to give every numeric Dial an absolute per-attempt deadline; a
timed-out Dial fails, closes and releases its slot so the next candidate can be
admitted. Without an attempt timeout, a full set of black-holed attempts may
hold every slot until the overall deadline. Reports expose
`capacity_limited`, `unattempted_count`, `active_attempts` and
`blocked_by_attempt_capacity` so this condition is observable.

Family-specific local addresses avoid applying an IPv4 bind address to an IPv6
attempt or the reverse. Ordinary Stream capacity and chunk-size options are
forwarded to each numeric Dial.

## Reports and failures

Success returns a report alongside the Stream:

```lua
{
  kind = 'dial',
  strategy = 'happy_eyeballs_v2',
  status = 'connected',
  destination_ordering = 'host',
  maximum_candidates = 64,
  maximum_active_attempts = 64,
  capacity_limited = false,
  winner = {
    address = address,
    family = 'inet6',
    attempt = 1,
  },
  attempts = {
    {
      address = address,
      family = 'inet6',
      status = 'succeeded',
      started_at = 0.0,
      completed_at = 0.012,
    },
  },
  families = {
    inet6 = { done = true, addresses = {...} },
    inet4 = { done = false, addresses = {...} },
  },
}
```

On terminal failure, `connect` returns `nil, err`; the same report is
available as `err.report`. Individual attempt errors are retained. Resolver
errors are returned directly when no connection attempt could be made;
otherwise terminal exhaustion is reported as `connect_failed` with the attempt
history.

Reports use monotonic Runtime times. They are intended for diagnostics and
conformance tests rather than as a persistent serialisation format.

## Scope and custody guarantee

The internal custody tree is:

```text
Dial (strategy: happy_eyeballs_v2)
└── private driver scope
    ├── resolver Query
    ├── numeric Dial 1
    ├── numeric Dial 2
    └── selected Stream, until collected
```

The winning numeric Dial first moves its Stream into the private driver scope.
Collecting the Dial result then moves that Stream into the caller's target
scope. Every other resource remains in the private tree and is closed through
ordinary Closure. This prevents a late successful attempt from leaking a
socket after another attempt has already won.
