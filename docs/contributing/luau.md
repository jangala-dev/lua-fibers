# Luau build programme

Luau uses a generated source tree because its module loader differs from stock Lua. The generated target retains the same execution-frontier kernel and public semantics.

## Commands

```sh
make build-luau
make check-luau
make test-luau-smoke
make test-luau-portable
make test-luau
```

The build is written to `build/luau/`. `scripts/build-luau.lua`:

- computes the required source closure;
- rewrites logical imports to `.luaurc` aliases;
- removes stock-Lua `package.path` test preludes;
- generates one module per selected test;
- emits smoke and portable test runners;
- rejects missing or stale test classifications.

`tests/luau/profile.lua` defines the portable test set and classifies every `test_*.lua` file. Host-specific native-provider tests remain outside the standalone Luau run.

## Roblox

The Roblox integration is a host adapter, not a second concurrency model. One Fibers runtime is driven through bounded application turns. Roblox callbacks queue or coalesce external deliveries and request a later turn; they do not enter transactional search recursively.

The stock-Lua fake-engine suite covers the portable driver, event adapters, shutdown handling and lifetime behaviour. A real Studio smoke place remains a separate release gate for Instances and engine scheduler behaviour.

## Distribution

The generated alias-based tree is the current analysis and test artefact. A future distribution may also provide a bundle, but it must be reproducible from the stock Lua sources and preserve the same module closure.
