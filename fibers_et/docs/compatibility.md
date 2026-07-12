# Lua compatibility

The production source uses the Lua 5.1 grammar and is intended to remain portable across stock Lua, LuaJIT and TeXLua. A maintained interpreter-version matrix will be added later as part of release engineering.

Compatibility paths cover standard-library and coroutine differences:

```text
unpack                 table.unpack or the Lua 5.1 global unpack
yieldable protection   coroutine-backed fibers.pcall and fibers.xpcall
coroutine identity     normalised in fibers.internal.protected
bit operations         confined to optional native host backends
```

Code which may suspend must use `fibers.pcall`, `fibers.xpcall`, or the internal protected-call helper. Native Lua 5.1 `pcall` and `xpcall` cannot yield across their C boundary.

## Current verification

```sh
lua tests/run_all.lua
FIBERS_MACHINE=reference lua tests/run_all.lua
lua tests/run_protected_fallback.lua
lua tests/test_reference_lazy.lua
```

These checks provide evidence for the portable pure-host path and agreement between the trail and copy-on-branch evaluators. They are not a substitute for a stock-Lua version matrix or environment-specific native-backend testing.

Optional providers such as LuaJIT FFI, CFFI, luaposix and nixio require separate CI environments with their dependencies installed.

## Authoring rules

Portable code in this repository should:

```text
avoid syntax introduced after Lua 5.1
use table.unpack or unpack through a local compatibility binding
avoid relying on native yieldable pcall in Lua 5.1
avoid undefined length behaviour for sparse arrays
preserve nil-bearing multiple values through explicit packed tuples
keep bitwise syntax and FFI declarations inside optional backend modules
```

Operation and result code must preserve the exact number of return values. The kernel uses packed tables with an explicit `n` field for this reason.

## Future matrix work

Before a stable release, compatibility claims should be checked against explicit interpreter versions and operating-system environments. The planned matrix should cover:

```text
stock Lua versions selected for support
LuaJIT
TeXLua
both trail and reference evaluators
isolated protected-call paths
available native host providers
all examples and source compilation
```

Until that matrix exists, compatibility beyond the current Lua 5.1/LuaJIT/TeXLua path is an intended design constraint rather than a continuously verified release guarantee.
