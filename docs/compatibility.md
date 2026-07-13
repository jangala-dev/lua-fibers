# Lua compatibility

The production source uses the Lua 5.1 grammar. The version 1 support policy is
limited to:

```text
Lua 5.1
Lua 5.2
Lua 5.3
Lua 5.4
Lua 5.5
LuaJIT v2.1
Luau
```

LuaJIT support follows the maintained `v2.1` production branch. Release and CI
environments should record the exact tested commit. Luau is a distinct runtime
target: it does not share the stock-Lua module-loading and native-extension
environment, so its loader and host adapter are verified separately.

Compatibility paths cover standard-library and coroutine differences:

```text
unpack                 table.unpack or the Lua 5.1 global unpack
yieldable protection   coroutine-backed fibers.pcall and fibers.xpcall
coroutine identity     normalised in fibers.internal.protected
bit operations         confined to optional native host backends
```

Code which may suspend must use `fibers.pcall`, `fibers.xpcall`, or the internal
protected-call helper. Native Lua 5.1 `pcall` and `xpcall` cannot yield across
their C boundary.

## Development matrix

The development container builds all supported interpreters. The stock-Lua and
LuaJIT commands are versioned explicitly:

```text
lua5.1  lua5.2  lua5.3  lua5.4  lua5.5
luajit  luau    luau-analyze
```

LuaRocks wrappers install native modules into separate ABI-specific prefixes:

```text
luarocks-5.1 ... luarocks-5.5
luarocks-luajit
```

`cffi-lua` is installed for stock Lua 5.1–5.5. Native host adapters resolve
native bit operations first (LuaJIT's built-in `bit` library or Lua 5.3+
native operators), then a `bit` module, then global or installed `bit32`.
The `bit32` compatibility rock remains installed for Lua 5.1 and Lua 5.4.
`luaposix` is installed for Lua 5.1–5.4 and LuaJIT; its current
release does not declare Lua 5.5 support. The LuaJIT FFI backend uses LuaJIT's
built-in `ffi`. `nixio` is installed in the development container for Lua
5.1 and LuaJIT, the Lua 5.1 ABI family targeted by its upstream build defaults.

## Verification

From the repository root:

```sh
make test-matrix
make test-reference
lua5.1 tests/run_protected_fallback.lua
luajit -joff tests/run_all.lua
```

These checks should be combined with environment-specific native-host tests.
The reference solver is repository-only and is deliberately outside `src/`.

## Authoring rules

Portable production code should:

```text
avoid syntax introduced after Lua 5.1
use table.unpack or unpack through a local compatibility binding
avoid relying on native yieldable pcall in Lua 5.1
avoid undefined length behaviour for sparse arrays
preserve nil-bearing multiple values through explicit packed tuples
keep bitwise syntax and FFI declarations inside optional backend modules
```

Operation and result code must preserve the exact number of return values. The
kernel uses packed tables with an explicit `n` field for this reason.
