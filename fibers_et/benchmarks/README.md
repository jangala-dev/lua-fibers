# Benchmarks

`bench.lua` is a validating local-regression harness. Cases cover:

```text
local perform, map, and_then and wrap
Scalar reads, writes and version waits
Rendezvous and tensor-internal exchange
all/tensor products, deferred continuations, choice, or_else and backtracking
EventQueue delivery and Clock readiness
Effect merge and discharge
Region ownership
Task and Scope spawn and settlement
nursery policy
negotiated custody hand-off
```

Run from the repository root:

```sh
lua benchmarks/bench.lua
luajit benchmarks/bench.lua
texlua benchmarks/bench.lua
```

Controls:

```sh
FIBERS_BENCH_SCALE=5 lua benchmarks/bench.lua
FIBERS_BENCH_REPEATS=5 lua benchmarks/bench.lua
FIBERS_BENCH_CASE=product lua benchmarks/bench.lua
FIBERS_BENCH_FORMAT=csv lua benchmarks/bench.lua
FIBERS_BENCH_FORMAT=json lua benchmarks/bench.lua
```

The reported `us/op` uses each case's logical operation count. Some cases perform several transactions per logical operation. Results are for comparisons on the same machine and runtime configuration, not cross-machine performance claims.

## Focused diagnostic scripts

```text
flow.lua            Flow sequential and tensor throughput
petri_calendar.lua  constant-state and growing-state behaviour
region.lua          persistent ownership-ledger growth
search_cases.lua    search calls, rollbacks, trail entries and refresh statistics
```

These scripts are not part of the validating benchmark harness. The reference evaluator may be selected with `FIBERS_MACHINE=reference` for differential measurements.
