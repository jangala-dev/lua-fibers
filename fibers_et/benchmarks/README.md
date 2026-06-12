# Benchmarks

`bench.lua` is a validating benchmark harness intended to guide optimisation
work. It replaces the earlier small benchmark with grouped cases covering:

```text
local Op perform, map/bind, wrap
Cell reads, writes, and changed waits
Channel rendezvous and tensor-internal rendezvous
all/tensor products, deferred lane bind, choice, or_else, and backtracking
Source queue, external arrival, and clock readiness
Effect merge and publication
Region ownership
Task/Lifetime spawning and retirement
Nursery policy spawning
Negotiated lifetime handoff
```

Run from the repository root with any supported Lua host:

```sh
lua benchmarks/bench.lua
luajit benchmarks/bench.lua
texlua benchmarks/bench.lua
```

Useful controls:

```sh
FIBERS_BENCH_SCALE=5 lua benchmarks/bench.lua
FIBERS_BENCH_REPEATS=5 lua benchmarks/bench.lua
FIBERS_BENCH_CASE=product lua benchmarks/bench.lua
FIBERS_BENCH_FORMAT=csv lua benchmarks/bench.lua
FIBERS_BENCH_FORMAT=json lua benchmarks/bench.lua
```

The reported `us/op` value uses each case's logical operation count. Some cases
perform more than one transaction per logical operation; the benchmark is meant
for relative comparison across versions of this library, not for cross-machine
claims.
