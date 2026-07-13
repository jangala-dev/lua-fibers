# Development container

Opening the repository in a Dev Container bootstraps `make` first, then installs:

- Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8 and 5.5.0;
- LuaJIT from the maintained `v2.1` branch;
- Luau 0.728 and `luau-analyze`;
- LuaRocks 3.13.0;
- StyLua 2.5.2;
- `cffi-lua` for stock Lua 5.1–5.5;
- `luaposix` for Lua 5.1–5.4 and LuaJIT;
- the `bit32` compatibility rock for Lua 5.1 and Lua 5.4.

The system package set includes the compiler toolchain, CMake, Meson, Ninja,
`libffi` and OpenSSL headers, Lua readline dependencies, and the archive and patch tools
used by source builds and LuaRocks. Python 3 is present because Debian's Meson package
uses Python and `cffi-lua` is built with Meson; StyLua itself is a native binary and does
not require Python.

Each interpreter has a separate prefix under `/opt/fibers`, and the versioned
LuaRocks wrappers install into the corresponding prefix:

```sh
luarocks-5.1 install <rock>
luarocks-5.4 install <rock>
luarocks-5.5 install <rock>
luarocks-luajit install <rock>
```

`nixio` is deliberately opt-in because its available rock is old:

```sh
sudo make -f .devcontainer/Makefile rocks-nixio
```

For reproducible CI or release images, override `LUAJIT_REF` with an exact tested
commit rather than following the branch head.
