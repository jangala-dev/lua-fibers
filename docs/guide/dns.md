# Non-blocking DNS resolution

`fibers.dns` is a recursive-server stub resolver built entirely from Fibers
facilities. Network activity uses scoped datagram sockets, stream dials, timers
and ordinary owned tasks. No `getaddrinfo` call is made by this implementation.

```lua
local socket = require('fibers.socket')

local resolver = socket.dns_resolver({
  nameservers = {
    socket.ipv4_address('192.0.2.53', 53),
    socket.ipv6_address('2001:db8::53', 53),
  },
  timeout = 1.0,
  attempts = 2,
})

local query = socket.resolve_name('example.org', 443, {
  resolver = resolver,
})
local addresses, err = query:result()
assert(addresses, err)
```

The existing combined `socket.Query` lifecycle remains compatible. Closing a
query cancels its driver; scope settlement closes any UDP socket, TCP connection
or resolver task still owned by that query. Each address family is also
observable independently:

```lua
local ipv6 = fibers.perform(query:family_ready_op('inet6'))
local ipv4_state = fibers.perform(query:family_finished_op('inet4'))
local all_addresses, err = fibers.perform(query:result_op())
```

`family_ready_op` is success-only and becomes refutable when that family closes
without addresses. `family_finished_op` observes either terminal result. A and
AAAA therefore form two asynchronous producers with explicit closure, suitable
for direct consumption by a Happy Eyeballs coordinator.

## Implemented protocol behaviour

The resolver currently provides:

- concurrent A and AAAA questions;
- strict transaction id, peer, question, class and type validation;
- an EDNS(0) UDP payload advertisement, defaulting to 1232 octets;
- retries across configured recursive servers before the next attempt round;
- DNS-over-TCP fallback for truncated UDP responses;
- bounded CNAME following and loop detection;
- positive RRset caching and SOA-derived negative caching;
- `/etc/resolv.conf` name-server, search, timeout, attempts and `ndots` parsing;
- `/etc/hosts` lookup before DNS;
- secure transaction-id entropy from an injected callback or `/dev/urandom`;
- a bounded positive and negative cache, defaulting to 1024 entries;
- deterministic explicit configuration for embedded and ManualHost use.

Input decoding is bounded by message size, record count, label length, expanded
name length and compression-pointer depth. Malformed or unrelated datagrams are
discarded while the transaction deadline remains open.

Resolver configuration, hosts data and `/dev/urandom` are read through
`fibers.file`; the DNS path does not call `io.open`. A small Scalar once-gate
serialises each lazy file load, so concurrent A and AAAA producers share one
non-blocking read and cancellation reopens an unfinished load.

Transaction ids are taken from an injected `random_u16` callback when supplied,
then from `/dev/urandom` through `fibers.file`. Resolution fails by default when
neither secure source is available. A process-local weak fallback exists only
for constrained or deterministic environments which explicitly set
`allow_weak_random = true` (`require_secure_random = false` remains a compatibility
alias).

`maximum_cache_entries` bounds the resolver cache and defaults to 1024. Set it
to zero to disable caching. Eviction is deterministic first-in, first-out after
expired entries have been removed.

## Selection policy

An explicit resolver always wins:

```lua
socket.resolve_name('example.org', 443, { resolver = resolver })
```

The shorthand options `dns = true`, `nameservers = {...}` and `nameserver = ...`
construct a resolver for that query. Where a native host advertises
`resolver_blocking = true` and provides both datagram and stream sockets, the
socket resolver creates one DNS resolver per Runtime and reuses its cache.

If automatic DNS configuration is unavailable, the historical host resolver is
used as a compatibility fallback. Set `require_nonblocking = true` to return a
configuration error instead.

## Deliberate limits

This is a stub resolver which depends on a configured recursive server. It does
not perform iterative recursion, DNSSEC validation, mDNS, LLMNR, DNS over TLS or
DNS over HTTPS. It currently resolves numeric service ports only. Address
ordering and connection racing remain responsibilities of
[`socket.connect_name`](happy-eyeballs.md) rather than the DNS layer.
