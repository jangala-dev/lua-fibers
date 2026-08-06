# Fibers performance suite

The performance programs validate the execution-frontier kernel while measuring local throughput and search behaviour. Timed samples run without instrumentation; each case may then run once with instrumentation to explain the result.

## Main suite

```sh
texlua performance/suite.lua
FIBERS_PERF_TIERS=all texlua performance/suite.lua
FIBERS_PERF_FORMAT=csv FIBERS_PERF_OUTPUT=results.csv texlua performance/suite.lua
```

Controls:

```text
FIBERS_PERF_SCALE          workload multiplier
FIBERS_PERF_REPEATS        timed samples; the median is reported
FIBERS_PERF_WARMUP         0 disables warm-up runs
FIBERS_PERF_TIERS          simple, moderate, complex, or all
FIBERS_PERF_CASE           literal case-name filter
FIBERS_PERF_FORMAT         text, csv, or json
FIBERS_PERF_OUTPUT         optional output file
FIBERS_PERF_SEED           deterministic choice seed
FIBERS_PERF_DIAGNOSTICS    0 disables the separate diagnostic pass
FIBERS_PERF_TRACE          1 retains capped search events
FIBERS_PERF_SLOW_SEARCHES     number of slow-search summaries retained
```

Every workload validates its result. Measurements are local regression evidence, not cross-machine claims.

## Focused probes

```sh
texlua performance/frontier_suite.lua
texlua performance/exchange_frontier_suite.lua
texlua performance/resumability_probe.lua
texlua performance/store_view_suite.lua
texlua performance/io_baselines.lua
make profile-proof-io
```

The frontier suite checks selective invalidation and exact Retry retention. The exchange-frontier suite records the bounded-search cliffs for participant recruitment, role imbalance, perfect matching and Hall-deficient graphs. The resumability probe compares one-shot and bounded execution of the same search. The store-view suite measures speculative state projection. I/O programs exercise host-facing paths without changing kernel semantics.

## Instrumentation

Instrumentation is opt-in:

```lua
local Runtime = require('fibers.runtime')

local runtime = Runtime.new({
  instrumentation = {
    slow_search_limit = 16,
    trace = false,
  },
})

local report = runtime.instrumentation:report()
runtime.instrumentation:reset()
```

Reports contain cumulative counters, maxima, histograms, slow-search summaries and optional capped trace events. Important measures include search calls, branches, rollbacks, trail entries, frontier invalidations, retained-search resumes, candidate validation and commit activity.

Use the same interpreter, host, CPU policy and environment when comparing runs.
