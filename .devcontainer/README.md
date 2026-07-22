# Development container

Opening the repository in a Dev Container bootstraps `make` first, then installs:

- Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8 and 5.5.0;
- LuaJIT from the maintained `v2.1` branch;
- TexLua from Debian TeX Live;
- Luau 0.728 and `luau-analyze`;
- LuaRocks 3.13.0;
- StyLua 2.5.2;
- `cffi-lua` for stock Lua 5.1–5.5;
- `luaposix` for Lua 5.1–5.4 and LuaJIT;
- the `bit32` compatibility rock for Lua 5.1 and Lua 5.4;
- `nixio` 0.4.1 for Lua 5.1–5.5 and LuaJIT, installed from a repository-local rockspec pinned to an exact upstream commit.

The system package set includes the compiler toolchain, CMake, Meson, Ninja,
`libffi` and OpenSSL headers, Lua readline dependencies, and the archive and patch tools
used by source builds and LuaRocks. Python 3 is present because Debian's Meson package
uses Python and `cffi-lua` is built with Meson; StyLua itself is a native binary and does
not require Python.  TexLua is supplied by Debian's `texlive-binaries` package.

Each interpreter has a separate prefix under `/opt/fibers`, and the versioned
LuaRocks wrappers install into the corresponding prefix:

```sh
luarocks-5.1 install <rock>
luarocks-5.4 install <rock>
luarocks-5.5 install <rock>
luarocks-luajit install <rock>
```

`nixio` is part of the standard bootstrap for Lua 5.1–5.5 and LuaJIT.
Upstream declares Lua 5.1 or later and contains compatibility code for the
post-5.1 C API. The bootstrap builds it independently for every runtime and
runs the nixio host and file-descriptor host tests under each one. The public
LuaRocks entry is uploader-scoped and is not resolved by the default manifest,
so `.devcontainer/rocks/nixio-0.4.1-1.rockspec` uses the immutable upstream
commit for release v0.4.1. It also supplies `<limits.h>` because upstream
`process.c` uses `PATH_MAX` without including that standard header directly.

For reproducible CI or release images, override `LUAJIT_REF` with an exact tested
commit rather than following the branch head.

The repository-level targets exercise the additional runtimes:

```sh
make test-texlua
make build-luau
make check-luau
make test-luau
```

Luau currently has a separate portable smoke target and is not yet included in
`make test-matrix`.  See `docs/contributing/luau.md` for the promotion gates.
