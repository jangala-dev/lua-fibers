# Ledger kernel

The hierarchical ledger described here is now the sole production kernel. Its
current architecture is documented in [`kernel.md`](kernel.md).

The former parallel prototype under `src/fibers/internal/ledger_kernel/` was used
to establish semantic parity before the representation replacement. That
adapter directory, the view-based production store and the shared configurable
engine have been removed. The view implementation survives only with the
copy-on-branch evaluator under `reference/fibers/internal/`.

Select the production machine explicitly with:

```lua
Runtime.new({ machine = 'ledger' })
```

or:

```sh
FIBERS_MACHINE=ledger lua tests/run_all.lua
```

The default is also `ledger`. Use `machine = 'reference'` only for differential
tests and diagnostic comparison.
