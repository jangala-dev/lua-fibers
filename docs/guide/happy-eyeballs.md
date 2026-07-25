# Happy Eyeballs v2 named connections

`socket.connect_name` combines incremental A and AAAA resolution with staggered
IPv6 and IPv4 connection attempts. Resolution, candidate arrival, attempt
completion and delay expiry remain independent events. The first successful
Stream moves into the caller's scope; the private race scope settles every
resolver query, losing Dial and losing Stream before the call returns.

```lua
local socket = require('fibers.socket')

local connection, report = socket.connect_name('example.org', 443, {
  resolution_delay = 0.050,
  attempt_delay = 0.250,
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
- the first selected successful connection cancels and settles the remaining
  race;
- terminal failure requires both address sources to be closed, no candidate to
  remain, no attempt to be active and no successful connection to await
  collection.

## The race as an option algebra

One Scalar machine contains the closed-family flags, globally ordered
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

Candidate admission composes the Scalar selection, `socket.dial_op` admission
and the active-attempt state update in one option. The transaction allocates no
file descriptor speculatively: the numeric Dial starts its non-blocking socket
work only after admission commits. Attempt completion similarly combines the
Dial's custody transfer with the winner or failure state transition.

The effectful coordinator is deliberately small. Pure ordering and reporting
policy is kept in `fibers.internal.socket.happy_eyeballs_policy`; the race module
contains the transitions and the prioritised expression above.

## Owned named Dials

`socket.dial_name_op` admits an owned `NamedDial` and starts its private driver
after the option commits:

```lua
local dial = fibers.perform(socket.dial_name_op('example.org', 443))
local connection, report = dial:connect()
assert(connection, report)
```

`dial:connect()` is the direct launch-and-collection convenience. It returns
only after the winner has moved into the target scope and the private race has
settled. The lower-level lifecycle remains selectable:

```lua
local connection, err = fibers.perform(dial:result_op(target_scope))
local report = fibers.perform(dial:report_op())
local closed, close_err = fibers.perform(dial:closed_op())
```

`connected_op` is success-only. `failed_op` observes terminal failure.
`result_op` combines them through certified fallback. A successful connection
which has not yet been collected remains owned by the named Dial's driver scope.
Closing the Dial cancels resolution and every outstanding numeric Dial.

There is deliberately no `connect_name_op`. Starting the private driver is a
committed effect; its later connection result cannot be required by the same
transaction which admits that driver. The public split is therefore the same as
other effectful facilities: an option admits the owned handle, then its result
operations participate in subsequent choices.

## Resolver integration

The named Dial consumes `Query:family_finished_op` independently for `inet6`
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

local connection, report = socket.connect_name('example.org', 443, {
  resolver = resolver,
})
```

The DNS selection options accepted by `socket.resolve_name` are also accepted by
`socket.connect_name`: `dns`, `nameservers`, `nameserver`,
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
local connection, report = socket.connect_name('example.org', 443, {
  order_destinations = function(addresses, endpoint, opts)
    return application_destination_order(addresses, endpoint, opts)
  end,
})
```

A host may instead provide `sort_destination_addresses`. The older
`sort_addresses(addresses, family, endpoint, opts)` hook remains as a
per-family compatibility policy when no global policy is supplied.

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
  default_connect_timeout = 30.0,
  maximum_candidates = 64,
  maximum_active_attempts = 4,

  nodelay = true,
  local_address_inet6 = socket.ipv6_address('::', 0),
  local_address_inet4 = socket.ipv4_address('0.0.0.0', 0),

  resolver = resolver,
  resolver_options = {},
  dial_options = {},
}
```

A relative `timeout` begins when the admitted named-Dial driver starts. When no
explicit timeout or deadline is supplied, `default_connect_timeout` applies and
defaults to 30 seconds; set `timeout = false` or `default_connect_timeout = false`
to disable it. An absolute `deadline` uses the Runtime's monotonic clock. RFC
8305's 10 millisecond minimum connection-attempt delay is enforced.

`maximum_candidates` bounds retained DNS destinations and defaults to 64; the
report records any dropped candidates. `maximum_active_attempts` bounds pending
numeric Dials and defaults to four. Family-specific local addresses avoid
applying an IPv4 bind address to an IPv6 attempt or the reverse. Ordinary Stream
capacity and chunk-size options are forwarded to each numeric Dial.

## Reports and failures

Success returns a report alongside the Stream:

```lua
{
  kind = 'happy_eyeballs_v2',
  status = 'connected',
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

On terminal failure, `connect_name` returns `nil, err`; the same report is
available as `err.report`. Individual attempt errors are retained. Resolver
errors are returned directly when no connection attempt could be made;
otherwise terminal exhaustion is reported as `connect_failed` with the attempt
history.

Reports use monotonic Runtime times. They are intended for diagnostics and
conformance tests rather than as a persistent serialisation format.

## Scope and custody guarantee

The internal ownership tree is:

```text
NamedDial
└── private driver scope
    ├── resolver Query
    ├── numeric Dial 1
    ├── numeric Dial 2
    └── selected Stream, until collected
```

The winning numeric Dial first moves its Stream into the private driver scope.
Collecting the named result then moves that Stream into the caller's target
scope. Every other resource remains in the private tree and is closed through
ordinary settlement. This prevents a late successful attempt from leaking a
socket after another attempt has already won.
